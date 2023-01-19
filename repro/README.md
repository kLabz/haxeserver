# Repro tool

See [Recording setup](./Recording.md) to setup recording on your machine.

## Build the repro tool

To install dependencies, in haxeserver root:

```sh
haxelib newrepo
haxelib install --always install.hxml
```

You can then build `repro/repro.js` with:

```sh
haxe repro.hxml
```

## Using the tool

```
$ node repro/repro.js
[--path] <p> : Path to the repro recording directory (mandatory)
[--file] <f> : Log file to use in the recording directory. Default is `repro.log`.
[--port] <p> : Port to use internally for haxe server. Should *not* refer to an existing server. Default is `7000`.
[--silent]   : Only show results.
[--times]    : Log timing per request type.
```

In a workspace with a recording available, run the repro tool:

```sh
node /path/to/haxeserver/repro/repro.js --port 7001 --path .haxelsp/recording/20230113-080000/ --file repro.log
```

With:

 * `--path path/to/recording` (mandatory) path to the recording folder

 * `--port XXXX` (optional) set the port that will be used for internal server
   Choose a port that is usually free; making sure a crash of the repro tool
   didn't leave the server running is not part of the tool yet, and it's not
   checking if port was free atm either so you might have to handle that part
   yourself for now if needed.
   Default port is `7000`.

 * `--file repro.log` (optional) set the log file to use for repro
   Can be useful when reducing the recording for example, so you can duplicate
   the log file and do modifications without losing the original recording.
   Defaults to `repro.log`, the original log file created during recording.

### Included repro projects

 * [X is redefined from X #1](./XRedefined.md)
 * More repro samples to be added soon; they will likely move somewhere else
   later, likely when we tackle the compilation server unit tests project

## Recording log format

Example recording file:

```sh
# Some comment
+0s - userConfig
{"postfixCompletion":{"level":"filtered"},"displayPort":"auto","enableServerRecording":true,"serverRecordingPath":".vim/recording/","buildCompletionCache":true,"codeGeneration":{"functions":{"anonymous":{"argumentTypeHints":false,"returnTypeHint":"never","useArrowSyntax":true,"placeOpenBraceOnNewLine":false,"explicitPublic":false,"explicitPrivate":false,"explicitNull":false},"field":{"argumentTypeHints":true,"returnTypeHint":"non-void","useArrowSyntax":false,"placeOpenBraceOnNewLine":false,"explicitPublic":false,"explicitPrivate":false,"explicitNull":false}},"imports":{"style":"type","enableAutoImports":true},"switch_":{"parentheses":false}},"diagnosticsPathFilter":"${workspaceRoot}","enableCodeLens":false,"enableCompletionCacheWarning":true,"enableDiagnostics":true,"enableServerView":false,"enableSignatureHelpDocumentation":true,"exclude":["zpp_nape"],"importsSortOrder":"all-alphabetical","inlayHints":{"variableTypes":true,"parameterNames":true,"parameterTypes":false,"functionReturnTypes":true,"conditionals":false},"maxCompletionItems":1000,"renameSourceFolders":["src","source","Source","test","tests"],"useLegacyCompletion":false}
+0s - displayServer
{"path":"haxe","env":{},"arguments":[],"print":{"completion":false,"reusing":false},"useSocket":true}
+0s - displayArguments
["build.hxml"]
+0s - root "/git/haxe-libs/haxeserver"
+0.1s - checkoutGitRef
0cb108ebe477ed8982f079b3ab30cce71563497a
+0.4s - applyGitPatch
+0.5s - addGitUntracked
+0.5s - start
+0.6s # Untracked files copied successfully
+13.7s > serverRequest 2 "server/readClassPaths"
["--cwd","/git/haxe-libs/haxeserver","-D","display-details","--no-output","build.hxml","--display","{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"server/readClassPaths\"}"]
+15.2s < serverResponse 2 "server/readClassPaths"
{"result":{"files":489},"timestamp":1673624262.34344}
+27.4s > serverRequest "compilation"
["--cwd /git/haxe-libs/haxeserver","repro.hxml","-D","message-reporting=pretty"]
+37.6s < compilationResult
<<EOF
src/haxeserver/repro/HaxeRepro.hx:79: characters 9-16 : Warning : { parse : (__args : Array<Dynamic>) -> Void, getDoc : () -> String }
EOF
```

Log entries are in the following form:
```
+12.3s - command
```

Where:

 * `+12.3s` is the number of seconds since the start of the compilation server,
  and can be omitted.
 * `-` can be 4 different symbols:
	 * `-` for internal commands
	 * `>` for requests **to** server
	 * `<` for communication **from** server
	 * `#` for timed comments
 * `command` can be followed by an optional (numeric) `id`, and also for some
   commands a string `"method"`

Random notes:

 * Empty lines, lines starting with `#` and lines starting with `+X.Xs #` will
   be ignored during reproduction
 * Display requests have an id that is printed between the command
   (`serverRequest` or `serverResponse`) and the request method. It can be used
   to identify server response to a particular request (especially in rare cases
   where requests overlap). Id is purely informative and so is optional.
 * Some commands use extra data that will usually be printed on following lines
 * Configuration phase (`userConfig`, `displayArguments`, `displayServer`) is
   currently not used, and can be omitted in handwritten or reduced repro files
 * `start` command is when the requests actually start being sent, after
   configuration phase. Any request before this command will error.


## Debugging a recording

You can edit a `repro.log` file to reduce or debug the recording.

Some commands have been added for manual use:

```sh
- echo "This prints some text to the output"

# Pause repro script until user presses <ENTER>:
- pause

# Activate step by step mode (pause between all server requests):
- stepByStep 1
# Disable step by step
- stepByStep 0

# Print server response for next request:
- displayResponse
> serverRequest 42 "server/something"
["..."]

# Abort repro (with exit code) on first failure
# Currently supports compilation failure and (hacky) completion request failure
- abortOnFailure
# Can also be enabled/disabled
- abortOnFailure 0
- abortOnFailure 1
```

## Turn a recording into a test

Assertions can be added to check if replaying the recording gives the expected
result, and can be used for integration with testing frameworks or with
automated recording reduction tool (not implemented yet).

For better results, use `--silent` to skip other output.

```sh
# Next request is expected to fail
- assert fail
> serverRequest "compilation"
["build.hxml"]

# Next request is expected to succeed
- assert success
> serverRequest "compilation"
["build.hxml"]

# Additional assertion for completion requests: number of items expected
# (imply that the request is successful)
- assert 42 items
> serverRequest "display/completion"
["..."]

# Following asserts are to be used with `abortOnFailure` to make sense:
# Script is supposed to run to that point
- assert true
# This part of the script should be unreachable
- assert false
```

### Useful custom display requests

Any display request can be added to extract information from haxe server. Some
examples of requests that can be useful in debugging the state at various points
of the reproduction:

```sh
- displayResponse
> serverRequest "server/contexts"
["--display","{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/contexts\"}"]

- displayResponse
> serverRequest "server/memory/module"
["--display","{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/memory/module\",\"params\":{\"signature\":\"46758be9d6852a00c50c16bb8ef5c666\",\"path\":\"hxser.gen.CodeBuilder\"}}"]

- displayResponse
> serverRequest "server/module"
["--display","{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/module\",\"params\":{\"signature\":\"46758be9d6852a00c50c16bb8ef5c666\",\"path\":\"hxser.gen.CodeBuilder\"}}"]

- displayResponse
> serverRequest "server/type"
["--display","{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/type\",\"params\":{\"signature\":\"46758be9d6852a00c50c16bb8ef5c666\",\"modulePath\":\"hxser.gen.CodeBuilder\",\"typeName\":\"CodeBuilder\"}}"]
```

### Usage with server cache view

Can be used with vshaxe's server cache view by cheating a bit:

 * Set your vshaxe displayPort (`"haxe.displayPort"` config) to the port you're
   using for repro tool.
 * **Restart haxe language server** from vscode command palette right before running
   your repro script. I get better results with no haxe file opened, and using
   this command to start the server is enough to enable server cache view.
 * When using a recording from vscode, you will likely have a `"cache build"`
   entry in your recording; comment it when using server cache view, as server
   cache view will be triggering it too.
 * If you have server recording enabled in vshaxe, this session will be recorded
   too, including queries and results from server cache view.

