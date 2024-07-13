# micro

Micro is a lightweight compiler written in OCaml. It aims to provide a simple and efficient way to compile source code into executable binaries. 

# Example

```
begin
    a := 1;
    b := a + 1;
    b := b + 1;
    write (a,b);
    read(a,b);
    write (a+10, b+10);
end
```