--------------------------------------------------------------------
-- |
-- Module    : Text.JSON.Parsec
-- Copyright : (c) Galois, Inc. 2007-2009, Duncan Coutts 2015
--
--
-- Minimal implementation of Canonical JSON.
--
-- <http://wiki.laptop.org/go/Canonical_JSON>
--
-- A "canonical JSON" format is provided in order to provide meaningful and
-- repeatable hashes of JSON-encoded data. Canonical JSON is parsable with any
-- full JSON parser, but security-conscious applications will want to verify
-- that input is in canonical form before authenticating any hash or signature
-- on that input.
--
-- This implementation is derived from the json parser from the json package,
-- with simplifications to meet the Canonical JSON grammar.
--
-- TODO: Known bugs/limitations:
--
--  * Decoding/encoding Unicode code-points beyond @U+00ff@ is currently broken
--
module Text.JSON.Canonical
  ( JSValue(..)
  , Int54
  , parseCanonicalJSON
  , renderCanonicalJSON
  ) where

import Text.ParserCombinators.Parsec
         ( CharParser, (<|>), (<?>), many, between, sepBy
         , satisfy, char, string, digit, spaces
         , parse )
import Data.Bits (Bits, FiniteBits)
import Data.Char (isDigit, digitToInt)
import Data.Data (Data)
import Data.Function (on)
import Data.Int (Int64)
import Data.Ix (Ix)
import Data.List (foldl', sortBy)
import Data.Typeable (Typeable)
import Foreign.Storable (Storable)
import Text.Printf (PrintfArg)
import qualified Data.ByteString.Lazy.Char8 as BS

data JSValue
    = JSNull
    | JSBool     !Bool
    | JSNum      !Int54
    | JSString   String
    | JSArray    [JSValue]
    | JSObject   [(String, JSValue)]
    deriving (Show, Read, Eq, Ord)

-- | 54-bit integer values
--
-- JavaScript can only safely represent numbers between @-(2^53 - 1)@ and
-- @2^53 - 1@.
--
-- TODO: Although we introduce the type here, we don't actually do any bounds
-- checking and just inherit all type class instance from Int64. We should
-- probably define `fromInteger` to do bounds checking, give different instances
-- for type classes such as `Bounded` and `FiniteBits`, etc.
newtype Int54 = Int54 Int64
  deriving ( Bounded
           , Enum
           , Eq
           , Integral
           , Data
           , Num
           , Ord
           , Read
           , Real
           , Show
           , Ix
           , FiniteBits
           , Bits
           , Storable
           , PrintfArg
           , Typeable
           )

------------------------------------------------------------------------------

-- | Encode as \"Canonical\" JSON.
--
-- NB: Canonical JSON's string escaping rules deviate from RFC 7159
-- JSON which requires
--
--    "All Unicode characters may be placed within the quotation
--    marks, except for the characters that must be escaped: quotation
--    mark, reverse solidus, and the control characters (@U+0000@
--    through @U+001F@)."
--
-- Whereas the current specification of Canonical JSON explicitly
-- requires to violate this by only escaping the quotation mark and
-- the reverse solidus. This, however, contradicts Canonical JSON's
-- statement that "Canonical JSON is parsable with any full JSON
-- parser"
--
-- Consequently, Canonical JSON is not a proper subset of RFC 7159.
renderCanonicalJSON :: JSValue -> BS.ByteString
renderCanonicalJSON v = BS.pack (s_value v [])

s_value :: JSValue -> ShowS
s_value JSNull         = showString "null"
s_value (JSBool False) = showString "false"
s_value (JSBool True)  = showString "true"
s_value (JSNum n)      = shows n
s_value (JSString s)   = s_string s
s_value (JSArray vs)   = s_array  vs
s_value (JSObject fs)  = s_object (sortBy (compare `on` fst) fs)

s_string :: String -> ShowS
s_string s = showChar '"' . showl s
  where showl []     = showChar '"'
        showl (c:cs) = s_char c . showl cs

        s_char '"'   = showChar '\\' . showChar '"'
        s_char '\\'  = showChar '\\' . showChar '\\'
        s_char c     = showChar c

s_array :: [JSValue] -> ShowS
s_array []           = showString "[]"
s_array (v0:vs0)     = showChar '[' . s_value v0 . showl vs0
  where showl []     = showChar ']'
        showl (v:vs) = showChar ',' . s_value v . showl vs

s_object :: [(String, JSValue)] -> ShowS
s_object []               = showString "{}"
s_object ((k0,v0):kvs0)   = showChar '{' . s_string k0
                          . showChar ':' . s_value v0
                          . showl kvs0
  where showl []          = showChar '}'
        showl ((k,v):kvs) = showChar ',' . s_string k
                          . showChar ':' . s_value v
                          . showl kvs

------------------------------------------------------------------------------

parseCanonicalJSON :: BS.ByteString -> Either String JSValue
parseCanonicalJSON = either (Left . show) Right
                   . parse p_value ""
                   . BS.unpack

p_value :: CharParser () JSValue
p_value = spaces *> p_jvalue

tok              :: CharParser () a -> CharParser () a
tok p             = p <* spaces

{-
value:
   string
   number
   object
   array
   true
   false
   null
-}
p_jvalue         :: CharParser () JSValue
p_jvalue          =  (JSNull      <$  p_null)
                 <|> (JSBool      <$> p_boolean)
                 <|> (JSArray     <$> p_array)
                 <|> (JSString    <$> p_string)
                 <|> (JSObject    <$> p_object)
                 <|> (JSNum . fromIntegral <$> p_number)
                 <?> "JSON value"

p_null           :: CharParser () ()
p_null            = tok (string "null") >> return ()

p_boolean        :: CharParser () Bool
p_boolean         = tok
                      (  (True  <$ string "true")
                     <|> (False <$ string "false")
                      )
{-
array:
   []
   [ elements ]
elements:
   value
   value , elements
-}
p_array          :: CharParser () [JSValue]
p_array           = between (tok (char '[')) (tok (char ']'))
                  $ p_jvalue `sepBy` tok (char ',')

{-
string:
   ""
   " chars "
chars:
   char
   char chars
char:
   any byte except hex 22 (") or hex 5C (\)
   \\
   \"
-}
p_string         :: CharParser () String
p_string          = between (tok (char '"')) (tok (char '"')) (many p_char)
  where p_char    =  (char '\\' >> p_esc)
                 <|> (satisfy (\x -> x /= '"' && x /= '\\'))

        p_esc     =  ('"'   <$ char '"')
                 <|> ('\\'  <$ char '\\')
                 <?> "escape character"
{-
object:
    {}
    { members }
members:
   pair
   pair , members
pair:
   string : value
-}
p_object         :: CharParser () [(String,JSValue)]
p_object          = between (tok (char '{')) (tok (char '}'))
                  $ p_field `sepBy` tok (char ',')
  where p_field   = (,) <$> (p_string <* tok (char ':')) <*> p_jvalue

{-
number:
   int
int:
   digit
   digit1-9 digits
   - digit1-9
   - digit1-9 digits
digits:
   digit
   digit digits
-}

-- | Parse an int
--
-- TODO: Currently this allows for a maximum of 15 digits (i.e. a maximum value
-- of @999,999,999,999,999@) as a crude approximation of the 'Int54' range.
p_number         :: CharParser () Int54
p_number          = tok
                      (  (char '-' *> (negate <$> pnat))
                     <|> pnat
                     <|> zero
                      )
  where pnat      = (\d ds -> strToInt (d:ds)) <$> digit19 <*> manyN 14 digit
        digit19   = satisfy (\c -> isDigit c && c /= '0') <?> "digit"
        strToInt  = foldl' (\x d -> 10*x + digitToInt54 d) 0
        zero      = 0 <$ char '0'

digitToInt54 :: Char -> Int54
digitToInt54 = fromIntegral . digitToInt

manyN :: Int -> CharParser () a -> CharParser () [a]
manyN 0 _ =  pure []
manyN n p =  ((:) <$> p <*> manyN (n-1) p)
         <|> pure []
