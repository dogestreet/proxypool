import qualified JSON
import qualified POW

import Test.Tasty

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests = testGroup "All tests" [ JSON.tests, POW.tests ]
