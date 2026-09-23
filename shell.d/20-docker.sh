# Docker aliases (personal layer). Only defined when docker is present.

if command -v docker >/dev/null 2>&1; then
  alias dklc='docker ps -l'                       # last container
  alias dklcid='docker ps -l -q'                  # last container ID
  alias dklcip='docker inspect -f "{{range .NetworkSettings.Networks}}{{println .IPAddress}}{{end}}" $(docker ps -l -q)'
  alias dkps='docker ps'                          # running containers
  alias dkpsa='docker ps -a'                      # all containers
  alias dki='docker images'                       # images
  alias dkrmac='docker rm $(docker ps -a -q)'     # remove all containers
  alias dkrmui='docker images -q -f dangling=true | xargs -r docker rmi'  # remove untagged images
  alias dkelc='docker exec -it $(docker ps -l -q) bash'  # enter last container

  # Docker Swarm stacks, one compose file per stack:
  #   $DOCKER_STACKS_DIR/<stack>/<stack>.yml
  # The default follows the funkypenguin "Geek Cookbook" layout; override
  # DOCKER_STACKS_DIR in ~/.<shell>rc.local.
  #   dsd <stack> [compose-file]   deploy / update a stack
  #   dsr <stack>                  remove a stack
  dsd() {
    [ -n "${1:-}" ] || { echo "usage: dsd <stack> [compose-file]" >&2; return 2; }
    docker stack deploy "$1" -c "${2:-${DOCKER_STACKS_DIR:-/var/data/config}/$1/$1.yml}"
  }
  dsr() {
    [ -n "${1:-}" ] || { echo "usage: dsr <stack>" >&2; return 2; }
    docker stack rm "$1"
  }
fi
