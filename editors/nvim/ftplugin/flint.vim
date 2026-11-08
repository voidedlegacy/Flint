" Flint buffer settings: tabs for indentation (like Go), // comments.
setlocal commentstring=//\ %s
setlocal noexpandtab tabstop=4 shiftwidth=4
let b:undo_ftplugin = "setlocal commentstring< expandtab< tabstop< shiftwidth<"
