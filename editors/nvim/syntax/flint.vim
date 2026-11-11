" Vim/Neovim syntax file for Flint (.fl)
if exists("b:current_syntax")
  finish
endif

" Keywords
syntax keyword flintKeyword   fn type struct
syntax keyword flintStorage   var let mut
syntax keyword flintControl   if else for return
syntax keyword flintUnsafe    unsafe
syntax keyword flintType      i64 bool
syntax keyword flintBoolean   true false

" Function name right after `fn` (lookbehind, so the fn keyword still wins)
syntax match flintFuncName "\(\<fn\s\+\)\@<=\h\w*"

" Literals
syntax match  flintNumber "\<\d\+\>"
syntax match  flintEscape  contained "\\."
syntax region flintString  start=+"+ skip=+\\.+ end=+"+ end=+$+ contains=flintEscape

" Operators (in &mut, & is an operator and mut a keyword)
syntax match flintOperator "==\|!=\|<=\|>=\|[-+*/=&<>]"

" Comments (last, so // beats the / operator)
syntax keyword flintTodo    contained TODO FIXME NOTE XXX
syntax match   flintComment "//.*$" contains=flintTodo

" Link to standard groups so every colorscheme works
highlight default link flintKeyword  Keyword
highlight default link flintStorage  StorageClass
highlight default link flintControl  Conditional
highlight default link flintUnsafe   Exception
highlight default link flintType     Type
highlight default link flintFuncName Function
highlight default link flintNumber   Number
highlight default link flintString   String
highlight default link flintEscape   SpecialChar
highlight default link flintOperator Operator
highlight default link flintComment  Comment
highlight default link flintTodo     Todo
highlight default link flintBoolean  Boolean

let b:current_syntax = "flint"
