#!/bin/bash
# Initializes /srv/git/main.git and /srv/git/auditor.git as bare repos with
# the per-role update hook installed. Idempotent: existing repos are left
# alone (only the hook is refreshed).
set -euo pipefail

for repo in main auditor; do
    dir="/srv/git/${repo}.git"
    if [ ! -d "${dir}/objects" ]; then
        echo "Initializing bare repo: ${dir}"
        git init --bare --initial-branch=main "${dir}"
    else
        echo "Bare repo already exists: ${dir}"
    fi
    install -m 0755 /srv/hooks/update "${dir}/hooks/update"
    chown -R git:git "${dir}"
done

# main.git needs an initial empty commit so cloners can check out main
# without a "remote HEAD refers to nonexistent ref" warning. Done via a
# temporary worktree owned by git.
if ! git --git-dir=/srv/git/main.git rev-parse --verify main >/dev/null 2>&1; then
    echo "Seeding main.git with an initial empty commit..."
    tmp=$(mktemp -d)
    chown git:git "${tmp}"
    su git -s /bin/bash -c "
        cd '${tmp}' &&
        git init -q -b main &&
        git -c user.email=substrate@localhost -c user.name=substrate \
            commit -q --allow-empty -m 'initial empty commit' &&
        git remote add origin /srv/git/main.git &&
        GIT_USER=human git push -q origin main
    "
    rm -rf "${tmp}"
fi
