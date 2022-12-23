# cloudflare.sh
Just a little script I cooked up at work for updating records in Cloudflare hosted DNS zones. In the end we did not use the script, as there is already a much better project that does this (https://github.com/danielpigott/cloudflare-cli).

I tried to use bash as a proper programming language, with correct error handing and all. And while I did succeed bash has some deficiencies that make is hard to do this:

1) Functions are not really functions, but are rather command groupings that have their own positional arguments. This is evident by the lack of `return` keyword, the only way to return something for a function is to use `echo`. This obviously is very problematic, as it limits what you can output on the screen for logging purposes.
2) The only way to assign a value from a function to a variable is to use command substitution `NAME="$(echo 'Aleksandar')"`, command substitution gets executed in a subshell, and parent shell has no idea about the success or failure, unless you check the exit status after every variable assignment. This kinda reminded me of golang and `if err != nil { return err }`.

All in all, a fun little experiment I would not repeat. If you need a real programming language use one.
