# Sasshimi 🍣

[![Requirements](https://img.shields.io/badge/zig-master_(19.08.2021)-orange)](https://ziglang.org/)

A toy experiment to build a SASS compiler in Zig.

### Goals
1. Have fun when I don't want to work on [requestz](https://github.com/ducdetronquito/requestz)
2. Learn how a compiler works
3. ???
4. Profit, obviously


### Usage

```
zig build run -- "a SCSS formatted string"
```

### State

```scss
/* input.scss */
$zig-orange: #f7a41d;

form {
  margin: 0;
  padding: 0;

  .button {
    background-color: $zig-orange;
  }
}
```

```css
/* output.css */
form {
  margin: 0;
  padding: 0;
}

form .button {
  background-color: #f7a41d;
}
```
