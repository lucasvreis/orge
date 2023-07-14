module Org.Parser.Elements where

import Data.Text qualified as T
import Org.Builder qualified as B
import Org.Parser.Common
import Org.Parser.Definitions
import Org.Parser.MarkupContexts
import Org.Parser.Objects
import Relude.Extra hiding (elems, next)
import Replace.Megaparsec
import Prelude hiding (many, some)

-- | Read the start of a header line, return the header level
headingStart :: OrgParser Int
headingStart =
  try $
    (T.length <$> takeWhile1P (Just "heading bullets") (== '*'))
      <* char ' '
      <* skipSpaces

commentLine :: OrgParser OrgElementData
commentLine = try do
  _ <- char '#'
  blankline' <|> (char ' ' <|> fail "If this was meant as a comment, a space is missing here.") *> void anyLine'
  pure Comment

elements :: OrgParser OrgElements
elements = elementsIndented 0

elementsIndented :: Int -> OrgParser OrgElements
elementsIndented minI = mconcat <$> many e
  where
    e = elementIndented minI False

{- | Each element parser must consume till the start of a line or EOF.
This is necessary for correct counting of list indentations.
-}
elementIndented ::
  Int ->
  Bool ->
  OrgParser OrgElements
elementIndented minI paraEnd = try $ goKws []
  where
    goKws kws = do
      notFollowedBy headingStart
      i <- spacesOrTabs
      guard (i >= minI)
      optional affiliatedKeyword >>= \case
        Just akw -> goKws (akw : kws)
        Nothing -> withIndentLevel i $ finalize kws

    finalize kws = do
      v <-
        blank kws <|> B.element' kws <$> nonParaElement <|> do
          guard (not (paraEnd && null kws))
          paraIndented minI kws
      skipBlanks
      return v

    skipBlanks = do
      _ <- many blankline
      blankline' <|> pure ()

    blank kws = do
      blankline <|> blankline' *> guard (not $ null kws)
      return $ mconcat $ B.element . uncurry B.keyword <$> kws

    nonParaElement =
      choice
        [ commentLine
        , exampleBlock
        , srcBlock
        , exportBlock
        , greaterBlock
        , plainList
        , latexEnvironment
        , drawer
        , fixedWidth
        , keyword
        , horizontalRule
        , table
        , footnoteDef
        ]

paraIndented :: Int -> [(Text, KeywordValue)] -> OrgParser OrgElements
paraIndented minI kws = do
  (inls, next, _) <- withMContext__ (/= '\n') end (plainMarkupContext standardSet)
  return $ B.element' kws (B.para inls) <> next
  where
    end :: OrgParser OrgElements
    end =
      (eof $> mempty) <|> try do
        _ <- newline
        blankline' $> mempty
          <|> lookAhead headingStart $> mempty
          <|> lookAhead (try $ guard . (< minI) =<< spacesOrTabs) $> mempty
          <|> elementIndented minI True
{-# INLINABLE paraIndented #-}

-- traceWithPos :: String -> OrgParser ()
-- traceWithPos m = do
--   s <- getParserState
--   let
--     err :: ParseError Text Void = FancyError (stateOffset s) (one $ ErrorFail m)
--     bundle = ParseErrorBundle (err :| []) (statePosState s)
--   traceM $ errorBundlePretty bundle

-- * Plain lists

plainList :: OrgParser OrgElementData
plainList = try do
  fstItem <- withIndentLevel 0 listItem
  rest <- many listItem
  let kind = listItemType fstItem
      items = fstItem : rest
  return $ B.list kind items

listItem :: OrgParser ListItem
listItem = try do
  notFollowedBy headingStart
  indent <- spacesOrTabs
  i <- asks orgEnvIndentLevel
  guard (indent == i)
  bullet <- unorderedBullet <|> counterBullet
  hspace1 <|> lookAhead (void newline')
  cookie <- optional counterSet
  box <- optional checkbox
  tag <- case bullet of
    Bullet _ -> toList <$> option mempty itemTag
    _ -> return []
  els <- liftA2 (<>) (paraIndented (indent + 2) []) (elementsIndented (indent + 2))
  return (ListItem bullet cookie box tag (toList els))
  where
    unorderedBullet = try $ Bullet <$> satisfy \c -> c == '+' || c == '-' || c == '*'
    counterBullet = try do
      counter <- digits1 <|> T.singleton <$> satisfy isAsciiAlpha
      d <- satisfy \c -> c == '.' || c == ')'
      pure (Counter counter d)

counterSet :: OrgParser Int
counterSet =
  try $
    string "[@"
      *> parseNum
      <* char ']'
      <* hspace
  where
    parseNum = integer <|> asciiAlpha'

checkbox :: OrgParser Checkbox
checkbox =
  try $
    char '['
      *> tick
      <* char ']'
      <* (hspace1 <|> lookAhead (void newline'))
  where
    tick =
      char ' ' $> BoolBox False
        <|> char 'X' $> BoolBox True
        <|> char '-' $> PartialBox

itemTag :: OrgParser OrgObjects
itemTag = try do
  clearLastChar
  st <- getFullState
  (contents, found) <- findSkipping (not . isSpace) end
  guard found
  parseFromText st contents (plainMarkupContext standardSet)
  where
    end =
      try (hspace1 *> string "::" *> hspace1 $> True)
        <|> newline' $> False

-- * Lesser blocks

exampleBlock :: OrgParser OrgElementData
exampleBlock = try do
  _ <- string'' "#+begin_example"
  switches <- blockSwitches
  _ <- anyLine
  contents <- rawBlockContents end switches
  pure $ B.example switches contents
  where
    end = try $ hspace *> string'' "#+end_example" <* blankline'

fixedWidth :: OrgParser OrgElementData
fixedWidth = try do
  contents <- SrcLine <<$>> some (hspace *> string ": " *> anyLine')
  tabWidth <- getsO orgSrcTabWidth
  preserveIndent <- getsO orgSrcPreserveIndentation
  let lines' =
        if preserveIndent
          then map (srcLineMap (tabsToSpaces tabWidth)) contents
          else indentContents tabWidth contents
  pure $ B.example mempty lines'

srcBlock :: OrgParser OrgElementData
srcBlock = try do
  _ <- string'' "#+begin_src"
  lang <- option "" $ hspace1 *> someNonSpace
  switches <- blockSwitches
  args <- headerArgs
  contents <- rawBlockContents end switches
  pure $ B.srcBlock lang switches args contents
  where
    end = try $ hspace *> string'' "#+end_src" <* blankline'

headerArgs :: OrgParser [(Text, Text)]
headerArgs = do
  hspace
  fromList
    <$> headerArg
    `sepBy` hspace1
    <* anyLine'
  where
    headerArg =
      liftA2
        (,)
        (char ':' *> someNonSpace)
        ( T.strip . fst
            <$> findSkipping
              (not . isSpace)
              ( try $
                  lookAhead
                    ( newline'
                        <|> hspace1 <* char ':'
                    )
              )
        )

exportBlock :: OrgParser OrgElementData
exportBlock = try do
  _ <- string'' "#+begin_export"
  format <- option "" $ hspace1 *> someNonSpace
  _ <- anyLine
  contents <- T.unlines <$> manyTill anyLine end
  return $ B.export format contents
  where
    end = try $ hspace *> string'' "#+end_export" <* blankline'

-- verseBlock :: OrgParser OrgElements
-- verseBlock = try do
--   hspace
--   _ <- string'' "#+begin_verse"
--   undefined
--   where
-- end = try $ hspace *> string'' "#+end_export" <* blankline'

indentContents :: Int -> [SrcLine] -> [SrcLine]
indentContents tabWidth (map (srcLineMap $ tabsToSpaces tabWidth) -> lins) =
  map (srcLineMap $ T.drop minIndent) lins
  where
    minIndent = maybe 0 minimum1 (nonEmpty $ map (indentSize . srcLineContent) lins)
    indentSize = T.length . T.takeWhile (== ' ')

tabsToSpaces :: Int -> Text -> Text
tabsToSpaces tabWidth txt =
  T.span (\c -> c == ' ' || c == '\t') txt
    & first
      ( flip T.replicate " "
          . uncurry (+)
          . bimap T.length ((* tabWidth) . T.length)
          . T.partition (== ' ')
      )
    & uncurry (<>)

rawBlockContents :: OrgParser void -> Map Text Text -> OrgParser [SrcLine]
rawBlockContents end switches = do
  contents <- manyTill (rawBlockLine switches) end
  tabWidth <- getsO orgSrcTabWidth
  preserveIndent <- getsO orgSrcPreserveIndentation
  pure $
    if preserveIndent || "-i" `member` switches
      then map (srcLineMap (tabsToSpaces tabWidth)) contents
      else indentContents tabWidth contents

quotedLine :: OrgParser Text
quotedLine = do
  (<>)
    <$> option "" (try $ char ',' *> (string "*" <|> string "#+"))
    <*> anyLine

rawBlockLine :: Map Text Text -> OrgParser SrcLine
rawBlockLine switches =
  try $ applyRef =<< quotedLine
  where
    (refpre, refpos) =
      maybe
        ("(ref:", ")")
        (second (T.drop 2) . T.breakOn "%s")
        $ lookup "-l" switches
    applyRef txt
      | Just (content, ref, _) <- breakCap refCookie txt =
          pure $ RefLine "" ref content
      | otherwise = pure $ SrcLine txt
    refCookie :: Parser Text
    refCookie = do
      space1 <* string refpre
      toText
        <$> someTill
          (satisfy $ \c -> isAsciiAlpha c || isDigit c || c == '-' || c == ' ')
          (string refpos)

blockSwitches :: OrgParser (Map Text Text)
blockSwitches = fromList <$> many (linum <|> switch <|> fmt)
  where
    linum :: OrgParser (Text, Text)
    linum = try $ do
      hspace1
      s <-
        T.snoc . one
          <$> oneOf ['+', '-']
          <*> char 'n'
      num <- option "" $ try $ hspace1 *> takeWhileP Nothing isDigit
      _ <- lookAhead spaceChar
      return (s, num)

    fmt :: OrgParser (Text, Text)
    fmt = try $ do
      hspace1
      s <- string "-l"
      hspace1
      str <-
        between (char '"') (char '"') $
          takeWhileP Nothing (\c -> c /= '"' && c /= '\n')
      _ <- lookAhead spaceChar
      return (s, str)

    switch :: OrgParser (Text, Text)
    switch = try $ do
      hspace1
      s <-
        T.snoc . one
          <$> char '-'
          <*> oneOf ['i', 'k', 'r']
      _ <- lookAhead spaceChar
      pure (s, "")

-- * Greater Blocks

greaterBlock :: OrgParser OrgElementData
greaterBlock = try do
  _ <- string'' "#+begin_"
  bname <- someNonSpace <* anyLine
  els <- withContext anyLine (end bname) elements
  return $ B.greaterBlock (blockType bname) els
  where
    blockType = \case
      (T.toLower -> "center") -> Center
      (T.toLower -> "quote") -> Quote
      other -> Special other
    end :: Text -> OrgParser Text
    end name = try $ hspace *> string'' "#+end_" *> string'' name <* blankline'

-- * Drawers

drawer :: OrgParser OrgElementData
drawer = try do
  _ <- char ':'
  dname <- takeWhile1P (Just "drawer name") (\c -> c /= ':' && c /= '\n')
  char ':' >> blankline
  els <- withContext anyLine end elements
  return $ B.drawer dname els
  where
    end :: OrgParser ()
    end = try $ hspace <* string'' ":end:" <* blankline'

-- * LaTeX Environments

latexEnvironment :: OrgParser OrgElementData
latexEnvironment = try do
  _ <- string "\\begin{"
  ename <-
    takeWhile1P
      (Just "latex environment name")
      (\c -> isAsciiAlpha c || isDigit c || c == '*')
  _ <- char '}'
  (str, _) <- findSkipping (/= '\\') (end ename)
  return $ B.latexEnvironment ename $ "\\begin{" <> ename <> "}" <> str <> "\\end{" <> ename <> "}"
  where
    end :: Text -> OrgParser ()
    end name = try $ string ("\\end{" <> name <> "}") *> blankline'

-- * Keywords and affiliated keywords

affiliatedKeyword :: OrgParser (Text, KeywordValue)
affiliatedKeyword = try do
  v <- keywordData
  let name = fst v
  unless ("attr_" `T.isPrefixOf` name) do
    akws <- getsO orgElementAffiliatedKeywords
    guard $ name `member` akws
  return v

keyword :: OrgParser OrgElementData
keyword = uncurry B.keyword <$> keywordData

keywordData :: OrgParser (Text, KeywordValue)
keywordData = try do
  _ <- string "#+"
  -- This is one of the places where it is convoluted to replicate org-element
  -- regexes: "#+abc:d:e :f" is a valid keyword of key "abc:d" and value "e :f".
  name <-
    T.toLower . fst <$> fix \me -> do
      res@(name, ended) <-
        findSkipping (\c -> c /= ':' && not (isSpace c)) $
          try $
            (newline' <|> void (satisfy isSpace)) $> False
              <|> char ':' *> notFollowedBy me $> True
      guard (not $ T.null name)
      guard ended <?> "keyword end"
      pure res
  hspace
  if "attr_" `T.isPrefixOf` name
    then do
      args <- B.attrKeyword <$> headerArgs
      return (name, args)
    else do
      text <- T.stripEnd <$> anyLine'
      parsedKws <- getsO orgElementParsedKeywords
      value <-
        if name `member` parsedKws
          then do
            st <- getFullState
            ParsedKeyword . toList
              <$> parseFromText st text (plainMarkupContext standardSet)
          else return $ ValueKeyword text
      return (name, value)

-- * Footnote definitions

footnoteDef :: OrgParser OrgElementData
footnoteDef = try do
  guard . (== 0) =<< asks orgEnvIndentLevel
  lbl <- start
  _ <- optional blankline'
  def <-
    withContext
      anyLine
      ( lookAhead $
          void headingStart
            <|> try (blankline' *> blankline')
            <|> void (try start)
      )
      elements
  return $ B.footnoteDef lbl def
  where
    start =
      string "[fn:"
        *> takeWhile1P
          (Just "footnote def label")
          (\c -> isAlphaNum c || c == '-' || c == '_')
        <* char ']'

-- * Horizontal Rules

horizontalRule :: OrgParser OrgElementData
horizontalRule = try do
  l <- T.length <$> takeWhile1P (Just "hrule dashes") (== '-')
  guard (l >= 5)
  blankline'
  return B.horizontalRule

-- * Tables

table :: OrgParser OrgElementData
table = try do
  _ <- lookAhead $ char '|'
  rows <- some tableRow
  return $ B.table rows
  where
    tableRow :: OrgParser TableRow
    tableRow = ruleRow <|> columnPropRow <|> standardRow

    ruleRow = try $ RuleRow <$ (hspace >> string "|-" >> anyLine')

    columnPropRow = try do
      hspace
      _ <- char '|'
      ColumnPropsRow
        <$> some cell
        <* blankline'
      where
        cell = do
          hspace
          Just <$> cookie <|> Nothing <$ void (char '|')
        cookie = try do
          a <-
            string "<l" $> AlignLeft
              <|> string "<c" $> AlignCenter
              <|> string "<r" $> AlignRight
          _ <- digits
          _ <- char '>'
          hspace
          void (char '|') <|> lookAhead newline'
          pure a

    standardRow = try do
      hspace
      _ <- char '|'
      B.standardRow
        <$> some cell
        <* blankline'
      where
        cell = do
          hspace
          char '|' $> mempty
            <|> withMContext
              (\c -> not $ isSpace c || c == '|')
              end
              (plainMarkupContext standardSet)
        end = try $ hspace >> void (char '|') <|> lookAhead newline'
