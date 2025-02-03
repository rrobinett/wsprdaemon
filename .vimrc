colorscheme industry
if has ("autocmd")
    filetype plugin indent on
endif

set expandtab
set shiftwidth=4
set softtabstop=4

set autoindent
set smartindent
set cindent

set nowrap

set term=xterm-256color
filetype plugin indent on
syntax on

if exists('$TERM_PROGRAM') && $TERM_PROGRAM == 'iTerm2'
    " Change cursor to a vertical bar in Insert mode
    let &t_SI = "\e[6 q"
    " Change cursor to a block in Normal mode
    let &t_EI = "\e[2 q"
endif
if exists('$TMUX')
    " tmux-specific cursor changes for Insert/Normal mode
    " Insert mode: vertical bar cursor
    let &t_SI = "\e[6 q"
    " Normal mode: block cursor
    let &t_EI = "\e[2 q"
endif
