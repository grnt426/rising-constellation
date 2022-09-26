# Rising Constellation

## License

This project contains parts released under different licenses:

### Images / Visuals

All images or visual assets are released under [Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/), *Copyright 2021 Clément Chassot / Loïc Lebas*.

### Music

All music files or sound assets are released under [Attribution-NonCommercial 4.0 International (CC BY-NC 4.0)](https://creativecommons.org/licenses/by-nc/4.0/), *Copyright 2021 Jérôme Clavien*.

### Source Code

Source code is released under the MIT license, *Copyright 2021 Gil Clavien*.

## Local Setup

Running the project locally:

1. postgres (database)
2. phoenix (front+back)

### Dependencies
* Erlang
* Elixir
* Docker

### 1. Database

* Make sure Docker Daemon is running
* `docker-compose up -d` to start a local postgres instance writing to `./pgdata`
* `mix deps.get`
* `mix ecto.create` to create the database
* `mix ecto.migrate` to setup the database schema
* `mix run priv/repo/seeds.exs` to insert fixtures

(using a prod DB backup locally: see [`db-restore.sh`](./db-restore.sh))

### 2. Front+Back

* `make ni`
* `mix deps.get` to fetch all dependencies
* `iex -S mix phx.server` (or simply `mix phx.server`)
* RC is now running at <http://localhost:4000>, portal at <http://localhost:4000/portal>

### Running Frontend Projects Independently

1. Disable the [corresponding watcher(s)](https://github.com/abdelaz3r/asylamba/blob/14c6a7ae18d929dab28651810a059f51f5fd1a2c/config/dev.exs#L15-L22)
2. Run the frontend project(s) manually: `npm run serve`

### Tests

* `MIX_ENV=test mix test`

## Distributed Local Setup

* Run at least two nodes:
  * `make a`
  * `make b`
  * (`make c`)

To shut down a node, type `:init.stop`

## Frontend Assets

### Vue Projects (front/(game|portal))

* For images and fonts, as `url()` in the CSS or `src=""` in HTML, put the assets in `public/` eg. `public/foo/bar.png` and reference them using `~public/foo/bar.png`
* Other static assets: put them in a subfolder of `public/`, eg. `public/media/foo.pdf` and they will become available at `/(game|portal)/media/foo.pdf`. Linking to them from of the vue projects then requires a relative link, eg. `href="media/foo.pdf`

### Phoenix (HTML or LiveView) Assets

* Assets in `/assets/static` will be available at `/`, eg. `/assets/static/FOO/logo.png` will be served at `/FOO/logo.png`

## Deployment

`make build upload`

* `make build` compiles the 3 frontends into a tar.gz and the backend as a release into a tar.gz, then extracts these archives.
* `make upload` sends these archives to a remote server.

The reason we assemble the release in a Docker image is to get a reproducible build on a linux system close to the prod servers.
Prod servers don't have access to the source code and don't have nodejs etc. installed.

### Adding a node

1. create instance from image `prod-template-1`
2. add IP as A record to nodes.rising-constellation.com
3. bashrc: export RELEASE_NODE=rc@163.172.181.27 (ip of the node), right after these (they should already be set):

```
export APPSIGNAL_PUSH_API_KEY=…
export RELEASE_COOKIE="…"
```

### Issues in Setup

#### nmake not found in PATH

```
** (Mix) "nmake" not found in the path. If you have set the MAKE environment variable,
please make sure it is correct.
```

Solution: Find `nmake` in an install of Microsoft Visual Studio. Example PATH: `C:\Program Files (x86)\Microsoft Visual Studio\2017\BuildTools\VC\Tools\MSVC\14.16.27023\bin\Hostx86\x86`
Yours will likely be a little different

#### Could not compile with nmake

```
** (Mix) Could not compile with "nmake" (exit status: 2).
One option is to install a recent version of
[Visual C++ Build Tools](https://visualstudio.microsoft.com/visual-cpp-build-tools/)
either manually or using [Chocolatey](https://chocolatey.org/) -
`choco install VisualCppBuildTools`.
```

Solution: Do as the error indicates to install a newer version.

#### Spaces in Absolute File Path
If you have space in the directory where the project is downloaded to, say for example `C:\Users\MyUser\My Project Directory\rising-constellation`,
that will fail.

Solution: Move the project somewhere else.

#### Elixir Crashes When Printing Version After Install
I get errors like this after installing Elixir:

```
Erlang/OTP 20 [erts-9.2] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:10] [kernel-poll:false]

{"init terminating in do_boot",{{badmatch,error},[{'Elixir.System',build,0,[{file,"lib/system.ex"},{line,172}]},{'Elixir.System',build_info,0,[{file,"lib/system.ex"},{line,164}]},{'Elixir.Kernel.CLI',parse_shared,2,[{file,"lib/kernel/cli.ex"},{line,153}]},{'Elixir.Kernel.CLI','shared_option?',3,[{file,"lib/kernel/cli.ex"},{line,113}]},{'Elixir.Kernel.CLI',main,1,[{file,"lib/kernel/cli.ex"},{line,14}]},{init,start_em,1,[]},{init,do_boot,3,[]}]}}
init terminating in do_boot ({{badmatch,error},[{Elixir.System,build,0,[{_},{_}]},{Elixir.System,build_info,0,[{_},{_}]},{Elixir.Kernel.CLI,parse_shared,2,[{_},{_}]},{Elixir.Kernel.CLI,shared_option?,

Crash dump is being written to: erl_crash.dump...done

```

Solution: make sure you have at least Erlang version 23 or greater installed. I needed to add the Erlang repo manually
to get the latest version on Ubuntu, as it only had version 20 available.

#### Make Ni Fails With '[[' Unrecognized Command
```
npm ERR! code 1
npm ERR! path F:\oss-rc\front\node_modules\paper
npm ERR! command failed
npm ERR! command C:\WINDOWS\system32\cmd.exe /d /s /c [[ $npm_config_heading == 'npm' ]] && npx npm-force-resolutions || true
npm ERR! '[[' is not recognized as an internal or external command,
npm ERR! operable program or batch file.
npm ERR! 'true' is not recognized as an internal or external command,
npm ERR! operable program or batch file.

npm ERR! A complete log of this run can be found in:
npm ERR!     C:\Users\kurtzbot\AppData\Local\npm-cache\_logs\2022-09-23T16_12_24_156Z-debug-0.log
make: *** [Makefile:15: ni] Error 1
```

Solution: Upgrade the `PaperJS` package in `package.json` from `"paper": "^0.12.11"` to `"paper": "^0.12.15"`

#### INotify Tools Is Needed
You got an error like this while inserting fixtures:

```
[error] `inotify-tools` is needed to run `file_system` for your system, check https://github.com/rvoicilas/inotify-tools/wiki for more information about how to install it. If it's already installed but not be found, appoint executable file with `config.exs` or `FILESYSTEM_FSINOTIFY_EXECUTABLE_FILE` env.
```

Solution: Not necessary, but you may install INotify tools as the error suggests if desired.

#### No Function Clause Matching Anonymous
```
** (FunctionClauseError) no function clause matching in anonymous fn/1 in :elixir_compiler_1.__FILE__/1

    The following arguments were given to anonymous fn/1 in :elixir_compiler_1.__FILE__/1:

        # 1
        {"admin@abc", "admin", "Admin", :admin, :active, :paid}

    priv/repo/seeds.exs:37: anonymous fn/1 in :elixir_compiler_1.__FILE__/1
    (elixir 1.13.4) lib/enum.ex:937: Enum."-each/2-lists^foreach/1-0-"/2
    (elixir 1.13.4) lib/code.ex:1183: Code.require_file/2
    (mix 1.13.4) lib/mix/tasks/run.ex:146: Mix.Tasks.Run.run/5
    (mix 1.13.4) lib/mix/tasks/run.ex:86: Mix.Tasks.Run.run/1
    (mix 1.13.4) lib/mix/task.ex:397: anonymous fn/3 in Mix.Task.run_task/3
    (mix 1.13.4) lib/mix/cli.ex:84: Mix.CLI.run_task/2
    (elixir 1.13.4) lib/code.ex:1183: Code.require_file/2
```

Solution: This *looks* like a last minute change that was made. Simply remove `, :paid` from both `seeds.exs` files.


#### Make Ni Fails

```
npm ERR! Linux 4.15.0-143-generic
npm ERR! argv "/usr/bin/node" "/usr/bin/npm" "install"
npm ERR! node v8.10.0
npm ERR! npm  v3.5.2
npm ERR! code EMISSINGARG

npm ERR! typeerror Error: Missing required argument #1
npm ERR! typeerror     at andLogAndFinish (/usr/share/npm/lib/fetch-package-metadata.js:31:3)
npm ERR! typeerror     at fetchPackageMetadata (/usr/share/npm/lib/fetch-package-metadata.js:51:22)
npm ERR! typeerror     at resolveWithNewModule (/usr/share/npm/lib/install/deps.js:456:12)
npm ERR! typeerror     at /usr/share/npm/lib/install/deps.js:457:7
npm ERR! typeerror     at /usr/share/npm/node_modules/iferr/index.js:13:50
npm ERR! typeerror     at /usr/share/npm/lib/fetch-package-metadata.js:37:12
npm ERR! typeerror     at addRequestedAndFinish (/usr/share/npm/lib/fetch-package-metadata.js:82:5)
npm ERR! typeerror     at returnAndAddMetadata (/usr/share/npm/lib/fetch-package-metadata.js:117:7)
npm ERR! typeerror     at pickVersionFromRegistryDocument (/usr/share/npm/lib/fetch-package-metadata.js:134:20)
npm ERR! typeerror     at /usr/share/npm/node_modules/iferr/index.js:13:50
npm ERR! typeerror This is an error with npm itself. Please report this error at:
npm ERR! typeerror     <http://github.com/npm/npm/issues>
npm ERR! Linux 4.15.0-143-generic
npm ERR! argv "/usr/bin/node" "/usr/bin/npm" "install"
npm ERR! node v8.10.0
npm ERR! npm  v3.5.2
npm ERR! code EMISSINGARG

npm ERR! typeerror Error: Missing required argument #1
npm ERR! typeerror     at andLogAndFinish (/usr/share/npm/lib/fetch-package-metadata.js:31:3)
npm ERR! typeerror     at fetchPackageMetadata (/usr/share/npm/lib/fetch-package-metadata.js:51:22)
npm ERR! typeerror     at resolveWithNewModule (/usr/share/npm/lib/install/deps.js:456:12)
npm ERR! typeerror     at /usr/share/npm/lib/install/deps.js:457:7
npm ERR! typeerror     at /usr/share/npm/node_modules/iferr/index.js:13:50
npm ERR! typeerror     at /usr/share/npm/lib/fetch-package-metadata.js:37:12
npm ERR! typeerror     at addRequestedAndFinish (/usr/share/npm/lib/fetch-package-metadata.js:82:5)
npm ERR! typeerror     at returnAndAddMetadata (/usr/share/npm/lib/fetch-package-metadata.js:117:7)
npm ERR! typeerror     at pickVersionFromRegistryDocument (/usr/share/npm/lib/fetch-package-metadata.js:134:20)
npm ERR! typeerror     at /usr/share/npm/node_modules/iferr/index.js:13:50
npm ERR! typeerror This is an error with npm itself. Please report this error at:
npm ERR! typeerror     <http://github.com/npm/npm/issues>
WARN engine eslint@7.32.0: wanted: {"node":"^10.12.0 || >=12.0.0"} (current: {"node":"8.10.0","npm":"3.5.2"})
npm ERR! Linux 4.15.0-143-generic
npm ERR! argv "/usr/bin/node" "/usr/bin/npm" "install"
npm ERR! node v8.10.0
npm ERR! npm  v3.5.2
npm ERR! code EMISSINGARG

npm ERR! typeerror Error: Missing required argument #1
npm ERR! typeerror     at andLogAndFinish (/usr/share/npm/lib/fetch-package-metadata.js:31:3)
npm ERR! typeerror     at fetchPackageMetadata (/usr/share/npm/lib/fetch-package-metadata.js:51:22)
npm ERR! typeerror     at resolveWithNewModule (/usr/share/npm/lib/install/deps.js:456:12)
npm ERR! typeerror     at /usr/share/npm/lib/install/deps.js:457:7
npm ERR! typeerror     at /usr/share/npm/node_modules/iferr/index.js:13:50
npm ERR! typeerror     at /usr/share/npm/lib/fetch-package-metadata.js:37:12
npm ERR! typeerror     at addRequestedAndFinish (/usr/share/npm/lib/fetch-package-metadata.js:82:5)
npm ERR! typeerror     at returnAndAddMetadata (/usr/share/npm/lib/fetch-package-metadata.js:117:7)
npm ERR! typeerror     at pickVersionFromRegistryDocument (/usr/share/npm/lib/fetch-package-metadata.js:134:20)
npm ERR! typeerror     at /usr/share/npm/node_modules/iferr/index.js:13:50
npm ERR! typeerror This is an error with npm itself. Please report this error at:
npm ERR! typeerror     <http://github.com/npm/npm/issues>
npm WARN deprecated babel-eslint@10.1.0: babel-eslint is now @babel/eslint-parser. This package will no longer receive updates.

npm ERR! Please include the following file with any support request:
npm ERR!     /home/granite/oss-rc/rising-constellation/assets/npm-debug.log
Makefile:14: recipe for target 'ni' failed
make: *** [ni] Error 1

```

Solution: You have an old version of NPM. Install a newer version. Version 16.15.1. Not 18

#### GLIBC Not Found

```
node: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.28' not found (required by node)
```

Solution: You have too *new* of a version of NPM. I think version 16.15.1 works best?


####

```
npm ERR! gyp ERR! node-gyp -v v3.8.0
```

Solution: Your install of node-gyp is too old, follow this:
https://github.com/nodejs/node-gyp/blob/main/docs/Updating-npm-bundled-node-gyp.md
