-- Copyright (c) 2014 Contributors as noted in the AUTHORS file
--
-- This file is part of frp-arduino.
--
-- frp-arduino is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- frp-arduino is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with frp-arduino.  If not, see <http://www.gnu.org/licenses/>.

module Arduino.Internal.CodeGen
    ( streamsToC
    ) where

import Arduino.Internal.DAG
import CCodeGen
import Control.Monad
import qualified Data.Map as M

data ResultVariable = Variable String CType
                    | FilterVariable String CType String
                    | ToFlatVariable String CType

data CType = CBit
           | CByte
           | CWord
           | CVoid
           | CList CType
           deriving (Eq, Show)

listSizeCType :: CType
listSizeCType = CByte

argIndexCType :: CType
argIndexCType = CByte

streamsToC :: Streams -> String
streamsToC = runGen . genStreamsCFile

genStreamsCFile :: Streams -> Gen ()
genStreamsCFile streams = do
    header "// This file is automatically generated."
    header ""
    header "#include <avr/io.h>"
    header "#include <stdbool.h>"
    header ""
    genCTypes
    genStreamCFunctions (sortStreams streams) M.empty
    line ""
    block "int main(void) {" $ do
        mapM genInit (streamsInTree streams)
        block "while (1) {" $ do
            mapM genInputCall (filter (null . inputs) (streamsInTree streams))
        line "}"
        line "return 0;"
    line "}"

genCTypes :: Gen ()
genCTypes = do
    header $ "struct list {"
    header $ "    " ++ cTypeStr listSizeCType ++ " size;"
    header $ "    void* values;"
    header $ "};"

genStreamCFunctions :: [Stream] -> M.Map String CType -> Gen ()
genStreamCFunctions streams streamTypeMap = case streams of
    []                   -> return ()
    (stream:restStreams) -> do
        cType <- genStreamCFunction streamTypeMap stream
        let updateStreamTypeMap = M.insert (name stream) cType streamTypeMap
        genStreamCFunctions restStreams updateStreamTypeMap

genStreamCFunction :: M.Map String CType -> Stream -> Gen CType
genStreamCFunction streamTypes stream = do
    let inputTypes = map (streamTypes M.!) (inputs stream)
    let inputMap = M.fromList $ zip [0..] inputTypes
    let args = streamArguments streamTypes stream
    let declaration = ("static void " ++ name stream ++
                       "(" ++ streamToArgumentList streamTypes stream ++ ")")
    cFunction declaration $ do
        genStreamInputParsing args
        outputNames <- genStreamBody inputMap (body stream)
        genStreamOuputCalling outputNames stream
        return $ resultType outputNames

streamArguments :: M.Map String CType -> Stream -> [(String, String, Int)]
streamArguments streamTypes =
    map (\(input, cType) -> ("input_" ++ show input, cTypeStr cType, input)) .
    zip [0..] .
    map (streamTypes M.!) .
    inputs

streamToArgumentList :: M.Map String CType -> Stream -> String
streamToArgumentList streamTypes stream
    | length (inputs stream) < 1 = ""
    | otherwise                  = cTypeStr argIndexCType ++ " arg, void* value"

genStreamInputParsing :: [(String, String, Int)] -> Gen ()
genStreamInputParsing args = do
    when ((length args) > 0) $ do
        forM_ args $ \(name, cType, _) -> do
            line $ "static " ++ cType ++ " " ++ name ++ ";"
        block "switch (arg) {" $ do
            forM_ args $ \(name, cType, n) -> do
                block ("case " ++ show n ++ ":") $ do
                    line $ name ++ " = *((" ++ cType ++ "*)value);"
                    line $ "break;"
        line $ "}"

genStreamBody :: M.Map Int CType -> Body -> Gen [ResultVariable]
genStreamBody inputMap body = case body of
    (Driver _ bodyLLI)     -> genLLI bodyLLI
    (Transform expression) -> genExpression inputMap expression

genStreamOuputCalling :: [ResultVariable] -> Stream -> Gen ()
genStreamOuputCalling results stream = do
    forM_ (outputs stream) $ \outputStreamName -> do
        forM_ results $ \res -> case res of
            (Variable name cType) -> do
                generateCall outputStreamName name
            (FilterVariable name cType condition) -> do
                block ("if (" ++ condition ++ ") {") $ do
                    generateCall outputStreamName name
                line "}"
            (ToFlatVariable name cType) -> do
                i <- var (cTypeStr listSizeCType)
                block ("for (" ++ i ++ " = 0; " ++ i ++ " < " ++ name ++ ".size; " ++ i ++ "++) {") $ do
                    generateCall outputStreamName ("((" ++ cTypeStr cType ++ "*)" ++ name ++ ".values)[" ++ i ++ "]")
                line "}"
    where
        generateCall (n, outputStreamName) resultVariable = do
            line (outputStreamName ++ "(" ++ show n ++ ", (void*)(&" ++ resultVariable ++ "));")

genExpression :: M.Map Int CType -> Expression -> Gen [ResultVariable]
genExpression inputMap expression = case expression of
    (Not operand) -> do
        [Variable result CBit] <- genExpression inputMap operand
        wrap ("!(" ++ result ++ ")") CBit
    (Even operand) -> do
        [Variable result CWord] <- genExpression inputMap operand
        wrap ("(" ++ result ++ ") % 2 == 0") CBit
    (Greater left right) -> do
        [Variable leftResult  CWord] <- genExpression inputMap left
        [Variable rightResult CWord] <- genExpression inputMap right
        wrap (leftResult ++ " > " ++ rightResult) CBit
    (Add left right) -> do
        [Variable leftResult  CWord] <- genExpression inputMap left
        [Variable rightResult CWord] <- genExpression inputMap right
        wrap (leftResult ++ " + " ++ rightResult) CWord
    (Sub left right) -> do
        [Variable leftResult  CWord] <- genExpression inputMap left
        [Variable rightResult CWord] <- genExpression inputMap right
        wrap (leftResult ++ " - " ++ rightResult) CWord
    (Input value) -> do
        variable ("input_" ++ show value) (inputMap M.! value)
    (ByteConstant value) -> do
        wrap (show value) CByte
    (BoolToBit operand) -> do
        genExpression inputMap operand
    (IsHigh operand) -> do
        genExpression inputMap operand
    (BitConstant value) -> do
        case value of
            High -> variable "true" CBit
            Low  -> variable "false" CBit
    (Many values) -> do
        x <- mapM (genExpression inputMap) values
        return $ concat x
    (ListConstant values) -> do
        x <- mapM (genExpression inputMap) values
        let exprs = concat x
        temp <- var "struct list"
        v <- label
        header $ cTypeStr (resultType exprs) ++ " " ++ v ++ "[" ++ show (length exprs) ++ "];"
        forM (zip [0..] exprs) $ \(i, (Variable x _)) -> do
            line $ v ++ "[" ++ show i ++ "] = " ++ x ++ ";"
        line $ temp ++ ".size = " ++ show (length exprs) ++ ";"
        line $ temp ++ ".values = (void*)" ++ v ++ ";"
        variable temp (CList $ resultType exprs)
    (NumberToByteArray operand) -> do
        [Variable r CWord] <- genExpression inputMap operand
        charBuf <- label
        header $ cTypeStr CByte ++ " " ++ charBuf ++ "[20];"
        line $ "snprintf(" ++ charBuf ++ ", 20, \"%d\", " ++ r ++ ");"
        temp <- var "struct list"
        line $ temp ++ ".size = strlen(" ++ charBuf ++ ");"
        line $ temp ++ ".values = " ++ charBuf ++ ";"
        variable temp (CList CByte)
    (WordConstant value) -> do
        variable (show value) CWord
    (If conditionExpression trueExpression falseExpression) -> do
        [Variable conditionResult CBit] <- genExpression inputMap conditionExpression
        [Variable trueResult cType] <- genExpression inputMap trueExpression
        [Variable falseResult cType] <- genExpression inputMap falseExpression
        temp <- var (cTypeStr cType)
        block ("if (" ++ conditionResult ++ ") {") $ do
            line $ temp ++ " = " ++ trueResult ++ ";"
        block "} else {" $ do
            line $ temp ++ " = " ++ falseResult ++ ";"
        line $ "}"
        variable temp cType
    (Fold expression startValue) -> do
        [Variable startValueResult cType] <- genExpression inputMap startValue
        header $ "static " ++ cTypeStr cType ++ " input_1 = " ++ startValueResult ++ ";"
        [Variable expressionResult cTypeNothing] <- genExpression (M.insert 1 cType inputMap) expression
        line $ "input_1 = " ++ expressionResult ++ ";"
        variable "input_1" cTypeNothing
    (Filter conditionExpression valueExpression) -> do
        [Variable conditionResult CBit] <- genExpression inputMap conditionExpression
        [Variable valueResult cType] <- genExpression inputMap valueExpression
        temp <- var "bool"
        line $ temp ++ " = false;"
        block ("if (" ++ conditionResult ++ ") {") $ do
            line $ temp ++ " = true;"
        line $ "}"
        return [FilterVariable valueResult cType temp]
    (Flatten expression) -> do
        [Variable x (CList a)] <- genExpression inputMap expression
        return [ToFlatVariable x a]

wrap :: String -> CType -> Gen [ResultVariable]
wrap expression cType = do
    name <- var (cTypeStr cType)
    line $ name ++ " = " ++ expression ++ ";"
    variable name cType

variable :: String -> CType -> Gen [ResultVariable]
variable name cType = return [Variable name cType]

genInit :: Stream -> Gen ()
genInit stream = case body stream of
    (Driver initLLI _) -> do
        genLLI initLLI
        return ()
    _ -> do
        return ()

genInputCall :: Stream -> Gen ()
genInputCall stream = do
    line (name stream ++ "();")

genLLI :: LLI -> Gen [ResultVariable]
genLLI lli = case lli of
    (WriteBit register bit value next) ->
        case value of
            High -> do
                line (register ++ " |= (1 << " ++ bit ++ ");")
                genLLI next
            Low -> do
                line (register ++ " &= ~(1 << " ++ bit ++ ");")
                genLLI next
    (WriteByte register value next) -> do
        [Variable x cType] <- genLLI value
        line (register ++ " = " ++ x ++ ";")
        genLLI next
    (WriteWord register value next) -> do
        [Variable x cType] <- genLLI value
        line (register ++ " = " ++ x ++ ";")
        genLLI next
    (ReadBit register bit) -> do
        x <- var "bool"
        line $ x ++ " = (" ++ register ++ " & (1 << " ++ bit ++ ")) == 0U;"
        return [Variable x CBit]
    (ReadWord register next) -> do
        x <- var (cTypeStr CWord)
        line $ x ++ " = " ++ register ++ ";"
        genLLI next
        return [Variable x CWord]
    (WaitBit register bit value next) -> do
        case value of
            High -> do
                line $ "while ((" ++ register ++ " & (1 << " ++ bit ++ ")) == 0) {"
                line $ "}"
        genLLI next
    (Switch name t f next) -> do
        [Variable x cType] <- genLLI name
        block ("if (" ++ x ++ ") {") $ do
            genLLI t
        block "} else {" $ do
            genLLI f
        line "}"
        genLLI next
    (Const x) -> do
        return [Variable x CBit]
    InputValue -> do
        return [Variable "input_0" CBit]
    End -> do
        return []

resultType :: [ResultVariable] -> CType
resultType vars = case vars of
    (x:y:rest) -> if extract x == extract y
                      then resultType (y:rest)
                      else error "different c types"
    [var]      -> extract var
    []         -> CVoid
    where
        extract (Variable _ cType) = cType
        extract (FilterVariable _ cType _) = cType
        extract (ToFlatVariable _ cType) = cType

cTypeStr :: CType -> String
cTypeStr cType = case cType of
    CBit    -> "bool"
    CByte   -> "uint8_t"
    CWord   -> "uint16_t"
    CVoid   -> "void"
    CList a -> "struct list"
