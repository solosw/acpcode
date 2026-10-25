# bao_markdown

The stashes' editor: markdown that shows what it says as it is written.

The text is the markdown itself, line for line; nothing is converted in
or out, so what is opened and saved unchanged is the same to the byte, and
an edit changes only what it touches. Each line shows what its marks make
(a heading, a list, bold, a link, a table, code…); where the caret is, the
marks show too, to be edited as they are written.

Only the lines in view are built, and the selection is painted by the
lines it covers, not built again: a long text is edited as a short one is.
