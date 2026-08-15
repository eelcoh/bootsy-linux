# Source this after Oh My Zsh selects its theme:
#   source /usr/share/bootsy/zsh/distrobox-prompt.zsh
# It prepends the Distrobox/container name without replacing the Candy prompt.
if [[ -n "${CONTAINER_ID:-}" ]]; then
  PROMPT="%F{cyan}[${CONTAINER_ID}]%f ${PROMPT}"
elif [[ -r /run/.containerenv ]]; then
  PROMPT="%F{cyan}[container]%f ${PROMPT}"
fi
