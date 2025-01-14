

fib : HasIO io => Integer -> io Integer
fib 0 = pure 0
fib 1 = pure 1
fib n = pure $ !(fib (n - 1)) + !(fib (n - 2))

main : IO ()
main =  do
  value <- getLine
  printLn !(fib (cast value))
