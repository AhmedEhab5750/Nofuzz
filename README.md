# Nofuzz
URL/endpoint fuzzer I built after running into cases where popular fuzzing tools gave zero output with a custom wordlist, even though manual browser testing on the same paths returned live 200/403/404 responses. Nofuzz uses a simple curl-based approach so you can always see exactly what's being requested and why a result shows or doesn't.
