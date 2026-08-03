# ── Interactive only ──────────────────────────────────────────
# This file replaces the distro's ~/.bashrc, which opened with this same
# guard. Without it, `ssh host cmd`, scp, rsync and sftp all source this file
# and break on the first byte of output.
case $- in
    *i*) ;;
      *) return ;;
esac

# ── PATH ──────────────────────────────────────────────────────
# Declared here so the CLI installers see their bin dir already on PATH and
# skip appending their own export block to this file (it is a stow symlink
# into ~/dotfiles — their edits would dirty the repo).
export PATH="$HOME/.local/bin:$PATH"
export PATH="$HOME/.npm-global/bin:$PATH"
export PATH="$HOME/.opencode/bin:$PATH"
export PATH="$HOME/.kimi-code/bin:$PATH"

# ── History ───────────────────────────────────────────────────
HISTFILE=~/.bash_history
HISTSIZE=50000
HISTFILESIZE=50000
# ignoredups + ignorespace, the two zsh setopts this file's zsh counterpart uses
HISTCONTROL=ignoreboth
shopt -s histappend    # append, never clobber, when several shells exit
shopt -s cmdhist       # keep a multi-line command as one history entry
shopt -s checkwinsize  # keep $LINES/$COLUMNS right after a resize

# ── Completion ────────────────────────────────────────────────
if ! shopt -oq posix; then
    if [ -r /usr/share/bash-completion/bash_completion ]; then
        source /usr/share/bash-completion/bash_completion
    elif [ -r /etc/bash_completion ]; then
        source /etc/bash_completion
    fi
fi

# ── Prompt ────────────────────────────────────────────────────
# Deliberately plain. This file is the fallback for machines that are staying
# on bash, so it must render on a serial console and a Linux VT with no Nerd
# Font — which is exactly where the starship prompt turns into tofu.
case "${TERM:-}" in
    dumb|linux|vt*|"") PS1='\u@\h:\w\$ ' ;;
    *)                 PS1='\[\e[1;34m\]\u@\h\[\e[0m\]:\[\e[1;32m\]\w\[\e[0m\]\$ ' ;;
esac

# ── Aliases: Navigation ───────────────────────────────────────
alias ..='cd ..'
alias ...='cd ../..'
# Clear screen + kitty scrollback (ESC[3J erases scrollback buffer)
clear() { command clear && printf "\033[3J"; }
alias c='clear'
alias x='exit'

# ── Aliases: eza ──────────────────────────────────────────────
if command -v eza &>/dev/null; then
    alias ls='eza --icons=always --group-directories-first'
    alias ll='eza -lah --icons=always --git --group-directories-first --time-style=relative'
    alias lt='eza --tree --icons=always --level=2'
    alias la='eza -a --icons=always --group-directories-first'
fi

# ── Aliases: Tools ────────────────────────────────────────────
command -v bat &>/dev/null && alias cat='bat'
alias grep='grep --color=auto'

# ── Aliases: System ───────────────────────────────────────────
# Built from what is actually installed — a server with no paru or flatpak
# would otherwise fail the whole chain on the first missing command.
_upd=""
if command -v pacman &>/dev/null; then
    _upd='sudo pacman -Syu'
    command -v paru &>/dev/null && _upd="$_upd && paru -Sua"
elif command -v apt &>/dev/null; then
    _upd='sudo apt update && sudo apt full-upgrade -y'
fi
if [ -n "$_upd" ]; then
    command -v flatpak &>/dev/null && _upd="$_upd && flatpak update"
    alias update="$_upd"
fi
unset _upd
alias reload='source ~/.bashrc'
alias bashrc='nano ~/.bashrc'
alias myip='curl ifconfig.me'
alias ports='ss -tulpn'

# ── Aliases: Git ──────────────────────────────────────────────
alias gs='git status'
alias ga='git add .'
alias gc='git commit -m'
alias gp='git push'
alias gl='git pull'
alias lg='lazygit'
alias glog='git log --oneline --graph --decorate'

# ── Aliases: Docker ───────────────────────────────────────────
alias dps='docker ps'
alias dc='docker compose'
alias dlog='docker logs -f'
alias dex='docker exec -it'

# ── Aliases: Misc ─────────────────────────────────────────────
alias ff='fastfetch'
# Kitty: reuse existing instance for near-instant startup
alias kitty='kitty --single-instance'

alias cc='claude --dangerously-skip-permissions'
alias ccr='claude --dangerously-skip-permissions --resume'
alias ccc='claude --dangerously-skip-permissions --continue'

alias phonecam='scrcpy --video-source=camera --camera-facing=back --camera-size=4080x3072 --video-codec=h265 --video-bit-rate=25M --max-fps=30 --v4l2-sink=/dev/video2 --no-playback'

# ── Deliberately not here ─────────────────────────────────────
# starship, zoxide, fzf and any plugin manager. This is the plain-bash
# fallback: the point of it is that it works on a box with none of them
# installed and no Nerd Font to render a prompt with. The zsh config is where
# that toolchain lives.
#
# Also absent: ~/scripts/pvpn/pvpn.zsh. It is zsh syntax, so sourcing it here
# would print a wall of syntax errors on every shell start. And the fzf-backed
# `fp` / `fkill` aliases, which need a tool this file does not assume.

# ── Fastfetch ─────────────────────────────────────────────────
command -v fastfetch &>/dev/null && fastfetch
