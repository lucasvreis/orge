-- |

module Tests.Document where
import Tests.Helpers
import NeatInterpolation
import Org.Parser.Document (propertyDrawer)

testDocument :: TestTree
testDocument = testGroup "Document"
  [ "Property drawer" ~: propertyDrawer $
    [
      [text|   :pRoPerTieS:
            :Fo^o3': 	 bar
              :foobar:
            :foobarbar: bla bla
             :ENd:
      |]
        =?> fromList [ ("Fo^o3'", "bar")
                     , ("foobar", "")
                     , ("foobarbar", "bla bla")
                     ]

    , [text|:properties:
            :end:
      |]
        =?> mempty
    ]
  ]
