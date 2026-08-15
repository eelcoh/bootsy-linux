# Showing Distrobox in the Oh My Zsh Candy prompt

Bootsy includes a small prompt fragment that preserves Candy and prepends the
current Distrobox name. Add this after the `ZSH_THEME="candy"`/Oh My Zsh setup
in `~/.zshrc` (or manage the line with chezmoi):

```zsh
source /usr/share/bootsy/zsh/distrobox-prompt.zsh
```

Inside a Distrobox the result looks like `[fedora] user@host ...`. Outside a
container the prompt is unchanged.
