# ghrepo and glrepo

Command-line tools for moving Git repositories around in bulk. ghrepo works on GitHub through the gh CLI, and glrepo works on GitLab through glab. Each one can copy, archive, transfer and rename repos, one at a time or a whole list in one go.

Copies keep the full history, with every branch and tag. Nothing is ever force-pushed or overwritten, so you can start a failed run again and it picks up where it stopped.

```
bin/ghrepo     GitHub tool
bin/glrepo     GitLab tool
install.sh     installer and updater
tests/         test suite with fake gh and glab
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/vulrun/repo-tools/main/install.sh | bash
```

That puts every tool from `bin/` into `~/.local/bin`. If that folder isn't on your PATH yet, the installer adds it in `~/.bashrc` (and in `~/.zshrc`, if you have one). Run the same line again to update.

From a clone:

```bash
git clone https://github.com/vulrun/repo-tools.git
cd repo-tools
./install.sh
```

| Setting | Default | What it changes |
|---|---|---|
| `DEST` | `~/.local/bin` | Where the tools go |
| `REF` | `main` | Branch or tag to install from |
| `REPO` | `vulrun/repo-tools` | GitHub repo to download from |

Pass them as environment variables, for example `curl ... | DEST=/usr/local/bin bash`.

To remove the tools:

```bash
./install.sh --uninstall
curl -fsSL https://raw.githubusercontent.com/vulrun/repo-tools/main/install.sh | bash -s -- --uninstall
```

### Requirements

| Tool | Needs |
|---|---|
| ghrepo | bash 4 or newer, git, gh |
| glrepo | bash 4 or newer, git, glab, jq |

macOS ships bash 3.2. Install a newer one with `brew install bash`; the tools pick it up through `/usr/bin/env bash`.

Sign in once:

```bash
gh auth login
gh auth refresh -h github.com -s workflow
glab auth login
```

Don't skip the workflow scope. Without it, GitHub rejects any push that contains files under `.github/workflows`, so `ghrepo copy` checks for it before it starts. The glab token needs the `api` and `write_repository` scopes.

You won't get a username or password prompt. ghrepo hands git your gh login and glrepo hands it your GitLab token, for that one command only. Your git config isn't changed.

## ghrepo

```
ghrepo <command> [arguments]
ghrepo <command> --help
```

| Command | What it does |
|---|---|
| `copy` | Copies repos into another org with full history. The originals stay. |
| `archive` | Makes repos read-only. |
| `transfer` | Moves repos to another org, issues and pull requests included. |
| `rename` | Renames a repo inside its org. |

### copy

```bash
ghrepo copy old-org/website new-org                # creates new-org/website
ghrepo copy old-org/website new-org/website-v2     # renamed copy
ghrepo copy old-org/{website,api,docs} new-org     # several at once
```

The last argument is the destination. With an org name, each copy keeps its source name. Give `org/new-name` instead and you get a renamed copy, which only works for a single source. New repos get the same visibility as their source.

Copy looks at the destination repo before pushing:

| Destination | What copy does |
|---|---|
| Doesn't exist | Creates it, then pushes |
| Exists, empty | Reuses it |
| Holds an earlier or partial copy of the source | Pushes only what's missing |
| Has commits the source doesn't have | Skips it and says so |

It never force-pushes. After a failure, fix the cause and run the same command again; it carries on from where it stopped.

Only code moves. Issues, pull requests, Actions secrets and variables, branch protection, webhooks, the wiki, releases and Git LFS objects stay behind.

Pushing branches into a repo counts as a push event, so any workflow with a push trigger will start in the destination. If you'd rather it didn't, turn Actions off for the destination org first and back on once the workflows are ready:

```bash
gh api -X PUT orgs/new-org/actions/permissions -f enabled_repositories=none
gh api -X PUT orgs/new-org/actions/permissions -f enabled_repositories=all
```

### archive

```bash
ghrepo archive archive-org/{website,old-api}
```

Repos that are missing or already archived get skipped. An owner can unarchive one later from its settings.

### transfer

```bash
ghrepo transfer old-org/{website,api} archive-org
```

Give the destination as an org name only; each repo keeps its name. Issues, pull requests, stars and settings move with it, and GitHub redirects the old URL. You need permission to create repos in the destination org.

This is a move. Run `copy` first if the code should also stay where it is. Later on, don't create a new repo with the old name in the old org: that breaks the redirect.

### rename

```bash
ghrepo rename new-org/website website-v2
```

GitHub redirects the old name. Point local clones at the new one with `git remote set-url origin https://github.com/new-org/website-v2.git`.

## glrepo

The same four commands with the same safety rules, for GitLab. Groups take the place of orgs, and subgroups work anywhere a group does.

```bash
glrepo copy     old-group/website new-group
glrepo copy     old-group/{website,api} new-group/backend
glrepo copy     old-group/website new-group/website-v2
glrepo archive  archive-group/{website,old-api}
glrepo transfer old-group/{website,api} archive-group
glrepo rename   new-group/website website-v2
```

Where it differs from ghrepo:

- `copy` checks whether the destination is an existing group or user namespace. When it is, copies keep their names; otherwise the last part of the path becomes the new name.
- Pushes carry the `ci.skip` push option, so GitLab doesn't start pipelines for copied branches.
- `transfer` needs the Owner role on each project and at least Maintainer on the destination group.
- GitHub Actions files arrive as plain files. GitLab pipelines come from `.gitlab-ci.yml`.

For a self-hosted GitLab, set `GL_HOST` (glrepo also reads glab's own `GITLAB_HOST`):

```bash
GL_HOST=gitlab.example.com glrepo copy group/app other-group
```

Pushes use `GITLAB_TOKEN` when it's set, otherwise the token glab saved at login.

## Many repos at once

`copy`, `archive` and `transfer` take any number of repos, written in any of these forms:

| Form | Example |
|---|---|
| Separate arguments | `old-org/website old-org/api` |
| Shell braces | `old-org/{website,api,docs}` |
| Comma list in quotes | `"old-org/website,api,docs"` |

Your shell expands the braces before the tool sees them, so they need at least one comma and no spaces. The quoted comma list works in any shell.

For a long list kept in a file, one `org/repo` per line:

```bash
xargs ghrepo archive < repos.txt
xargs -I{} ghrepo copy {} new-org < repos.txt
```

## Moving between GitHub and GitLab

Neither tool crosses platforms. Git itself doesn't mind, so a one-off move takes two git commands. Create the empty GitLab project first, then:

```bash
git clone --mirror https://github.com/old-org/website.git
git -C website.git push https://gitlab.com/new-group/website.git 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
```

After that, `ghrepo archive old-org/website` retires the original.

## Adding a tool

The installer picks up every file in `bin/`, so a new tool is one new file. To keep it in line with the others:

- Start from the header of `bin/ghrepo`, which sets up bash 4 and strict mode.
- Support `--help` and `--version`, plus `<command> --help` for each subcommand.
- Print `==>` lines for progress and `skip:` or `FAILED:` lines for anything that didn't happen, then finish with a one-line count.
- Never force-push or overwrite anything. Skip it and say why.
- Add tests to `tests/run.sh` and a section to this README.

## Tests

```bash
bash tests/run.sh
```

The suite runs both tools and the installer against fake `gh` and `glab` commands (in `tests/stubs`) that keep repos as local bare Git repos. It needs git and jq, but no network or accounts. CI runs it with shellcheck on every pull request.

## License

MIT. See `LICENSE`.
