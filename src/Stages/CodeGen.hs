module Stages.CodeGen
    ( streamsToC
    )
    where

import Control.Monad.State
import Data.List (intercalate)
import Data.Maybe (fromJust)
import qualified Data.Map as M

import qualified Types.AST as AST
import Types.DAG

streamsToC :: Streams -> String
streamsToC = unlines . runGen . genStreamsCFile

genStreamsCFile :: Streams -> Gen ()
genStreamsCFile streams = do
    header "#include <avr/io.h>"
    header "#include <util/delay.h>"
    header "#include <stdbool.h>"
    mapM (genStreamCFunction streams) (streamsInTree streams)
    line ""
    block "int main(void) {" $ do
        mapM genOutputInit (outputPins streams)
        block "while (1) {" $ do
            line "clock(0);"
            line "_delay_ms(1000);"
        line "}"
        line "return 0;"
    line "}"

genStreamCFunction :: Streams -> Stream -> Gen ()
genStreamCFunction streams stream = do
    let declaration = ("static void " ++ name stream ++
                       "(" ++ streamToArgumentList streams stream ++ ")")
    cFunction declaration $ do
        line $ (streamCType streams) stream ++ " output;"
        genStreamBody (body stream)
        mapM_ (\x -> line (x ++ "(output);")) (outputs stream)

streamToArgumentList :: Streams -> Stream -> String
streamToArgumentList streams stream =
    intercalate ", " $
    map (\(input, t) -> t ++ " input_" ++ show input) $
    zip [0..] $
    map (streamCType streams) (map (streamFromId streams) (inputs stream))

streamCType :: Streams -> Stream -> String
streamCType streams stream = case body stream of
    (OutputPin (AST.Pin _ _ _ _)) -> "bool"
    (OutputPin (AST.UART))        -> "char *"
    (Builtin "clock")             -> "unsigned int"
    (Transform expression)        -> expressionCType inputMap expression
    where
        inputMap = M.fromList $ zip [0..] $ map (streamCType streams) x
        x = (map (streamFromId streams) (inputs stream))

expressionCType :: M.Map Int String -> AST.Expression -> String
expressionCType inputMap expression = case expression of
    (AST.Input x)          -> fromJust $ M.lookup x inputMap
    (AST.Not _)            -> "bool"
    (AST.Even _)           -> "bool"
    (AST.StringConstant _) -> "char *"

genStreamBody :: Body -> Gen ()
genStreamBody body = case body of
    (OutputPin (AST.Pin _ portRegister _ pinMask)) -> do
        block "if (input_0) {" $ do
            line $ portRegister ++ " |= " ++ pinMask ++ ";"
        block "} else {" $ do
            line $ portRegister ++ " &= ~(" ++ pinMask ++ ");"
        line "}"
    (OutputPin (AST.UART)) -> do
        block "while (*input_0 != 0) {" $ do
            line $ "while ((UCSR0A & (1 << UDRE0)) == 0) {"
            line $ "}"
            line $ "UDR0 = *input_0;"
            line $ "input_0++;"
        line $ "}"
    (Transform expression) -> do
        e <- genExpression expression
        line $ "output = " ++ e ++ ";"
    (Builtin name) -> do
        temp <- label
        line $ "static unsigned int " ++ temp ++ " = 0U;"
        line $ temp ++ "++;"
        line $ "output = " ++ temp ++ ";"

genExpression :: AST.Expression -> Gen String
genExpression expression = case expression of
    (AST.Not expression) -> do
        inner <- genExpression expression
        return $ "!(" ++ inner ++ ")"
    (AST.Even expression) -> do
        inner <- genExpression expression
        return $ "(" ++ inner ++ ") % 2 == 0"
    (AST.Input value) -> do
        return $ "input_" ++ show value
    (AST.StringConstant value) -> do
        temp <- label
        line $ "char " ++ temp ++ "[] = " ++ show value ++ ";"
        return temp

genOutputInit :: AST.Output -> Gen ()
genOutputInit output = case output of
    (AST.Pin _ _ directionRegister pinMask) -> do
        line $ directionRegister ++ " |= " ++ pinMask ++ ";"
    (AST.UART) -> do
        line $ "#define F_CPU 16000000UL"
        line $ "#define BAUD 9600"
        line $ "#include <util/setbaud.h>"
        line $ "UBRR0H = UBRRH_VALUE;"
        line $ "UBRR0L = UBRRL_VALUE;"
        block "#if USE_2X" $ do
            line $ "UCSR0A |= (1 << U2X0);"
        block "#else" $ do
            line $ "UCSR0A &= ~((1 << U2X0));"
        line $ "#endif"
        line $ "UCSR0C = (1 << UCSZ01) |(1 << UCSZ00);"
        line $ "UCSR0B = (1 << RXEN0) | (1 << TXEN0);"

data GenState = GenState
    { labelCounter :: Int
    , indentLevel  :: Int
    , headerLines  :: [String]
    , bodyLines    :: [String]
    }

type Gen a = State GenState a

runGen :: Gen a -> [String]
runGen gen = reverse (headerLines genState) ++ reverse (bodyLines genState)
    where
        genState = execState gen emptyGenState

emptyGenState :: GenState
emptyGenState = GenState 0 0 [] []

label :: Gen String
label = do
    genState <- get
    modify $ \genState -> genState { labelCounter = 1 + labelCounter genState }
    return $ "temp" ++ show (labelCounter genState)

block :: String -> Gen a -> Gen a
block x gen = do
    line x
    indent gen
    where
        indent :: Gen a -> Gen a
        indent gen = do
            modify $ \genState -> genState { indentLevel = indentLevel genState + 1 }
            x <- gen
            modify $ \genState -> genState { indentLevel = indentLevel genState - 1 }
            return x

header :: String -> Gen ()
header line = do
    modify (prependLine line)
    where
        prependLine line genState = genState { headerLines = line : headerLines genState }

line :: String -> Gen ()
line line = do
    modify (prependLine line)
    where
        prependLine line genState = genState { bodyLines = ((concat (replicate (indentLevel genState) "  ")) ++ line) : bodyLines genState }

cFunction :: String -> Gen a -> Gen a
cFunction declaration gen = do
    header $ ""
    header $ declaration ++ ";"
    line $ ""
    x <- block (declaration ++ " {") gen
    line $ "}"
    return x
