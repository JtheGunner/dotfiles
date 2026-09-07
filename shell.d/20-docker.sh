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
  alias dsd='docker stack deploy "$1" -c /var/data/config/"$1"/"$1".yml'
  alias dsr='docker stack rm "$1"'
fi

# NOTE: the old dotfiles aliased `git` itself to a git-in-docker container
# (funkypenguin/git-docker) for hosts without git. That is dangerous with this
# setup (which assumes a real git + delta) and is intentionally left disabled:
#
#   alias git='docker run -v $PWD:/var/data -v /var/data/git-docker/data/.ssh:/root/.ssh funkypenguin/git-docker git'
