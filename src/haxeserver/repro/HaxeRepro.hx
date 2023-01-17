package haxeserver.repro;

import haxe.Json;
import haxe.Rest;
import haxe.display.Display;
import haxe.display.Protocol;
import haxe.display.Server;
import haxe.io.Path;
import js.Node;
import js.Node.console;
import js.node.Buffer;
import js.node.ChildProcess;
import js.node.child_process.ChildProcess as ChildProcessObject;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileInput;

import haxeLanguageServer.Configuration;
import haxeLanguageServer.DisplayServerConfig;
import haxeLanguageServer.documents.HxTextDocument;
import haxeserver.process.HaxeServerProcessConnect;
import languageServerProtocol.protocol.Protocol.DidChangeTextDocumentParams;
import languageServerProtocol.protocol.Protocol.FileEvent;

// TODO: open issue and/or improve error
// Module js.Node does not define type console
// import js.Node.console.error;

using StringTools;
using haxeLanguageServer.extensions.DocumentUriExtensions;
using haxeserver.repro.HaxeRepro;

class HaxeRepro {
	static inline var REPRO_PATCHFILE = 'status.patch';
	static inline var UNTRACKED_DIR:String = "untracked";
	static inline var NEWFILES_DIR:String = "newfiles";

	// Recording configuration
	var root:String = "./";
	var userConfig:UserConfig;
	var displayServer:DisplayServerConfig;
	var displayArguments:Array<String>;
	var gitRef:String;

	// Replay configuration
	var path:String;
	var silent:Bool = false;
	var port:Int = 7000;
	var filename:String = "repro.log";

	// Replay state
	var lineNumber:Int = 0;
	var gitStash:Bool = false;
	var stepping:Bool = false;
	var abortOnFailure:Bool = false;
	var displayNextResponse:Bool = false;
	var currentAssert:Assertion = None;
	var assertions = new Map<Int, AssertionItem>();

	/**
	 * When `abortOnFailure` hit a failure;
	 * We only continue to gather failed assertions for reporting.
	 */
	var aborted:Bool = false;

	var file:FileInput;
	var extractor = Extractor.init();
	var server:ChildProcessObject;
	var client:HaxeServerAsync;
	var started(get, never):Bool;
	function get_started():Bool return client != null;

	public static function main() new HaxeRepro();
	public static function plural(nb:Int):String return nb > 1 ? "s" : "";

	function new() {
		var handler = hxargs.Args.generate([
			@doc("Path to the repro recording directory (mandatory)")
			["--path"] => p -> path = p,
			@doc("Log file to use in the recording directory. Default is `repro.log`.")
			["--file"] => f -> filename = f,
			@doc("Port to use internally for haxe server. Should *not* refer to an existing server. Default is `7000`.")
			["--port"] => p -> port = p,
			@doc("Only show results.")
			["--silent"] => () -> silent = true,
			_ => a -> {
				Sys.println('Unknown argument $a');
				Sys.exit(1);
			}
		]);

		var args = Sys.args();
		if (args.length == 0) return Sys.println(handler.getDoc());
		handler.parse(args);

		if (path == null || path == "") {
			Sys.println(handler.getDoc());
			Sys.exit(1);
		}

		if (!FileSystem.exists(path) || !FileSystem.isDirectory(path)) {
			console.error('Invalid recording path provided, skipping repro.');
			Sys.exit(1);
		}

		var filepath = Path.join([path, filename]);
		if (!FileSystem.exists(filepath) || FileSystem.isDirectory(filepath)) {
			console.error('Invalid recording file provided, skipping repro.');
			Sys.exit(1);
		}

		this.file = File.read(filepath);
		next();
	}

	function start(done:Void->Void):Void {
		server = ChildProcess.spawn("haxe", ["--wait", Std.string(port)]);
		Sys.sleep(0.5);

		var process = new HaxeServerProcessConnect("haxe", port, []);
		client = new HaxeServerAsync(() -> process);
		done();
	}

	function pause(resume:Void->Void):Void {
		if (aborted) resume();
		Sys.print("Paused. Press <ENTER> to resume.");
		Sys.stdin().readLine();
		resume();
	}

	function done():Void {
		cleanup();

		if (assertions.iterator().hasNext()) {
			var nb = 0;
			var nbFail = 0;
			var detailed = new StringBuf();
			var summary = new StringBuf();

			for (l => res in assertions) {
				nb++;
				summary.add(res.success ? "." : "F");

				if (!res.success) {
					nbFail++;
					// TODO: better output
					detailed.add('$l: assertion failed ${res.assert} at line ${res.lineApplied}\n');
				}
			}

			Sys.println('$nb assertion${nb.plural()} with $nbFail failure${nbFail.plural()}: ${summary.toString()}');
			if (!silent) Sys.println(detailed.toString());
			if (nbFail > 0) Sys.exit(1);
		} else {
			Sys.println('Done.');
		}
	}

	function next() {
		var next = Node.process.nextTick.bind(next, []);
		if (file.eof()) return done();

		var line = getLine();
		if (line == "") return next();
		var l = lineNumber;

		try {
			switch (line.charCodeAt(0)) {
				case '#'.code: return next();

				case _ if (extractor.match(line)):
					// trace(l, extractor.entry);

					switch (extractor.entry) {
						// Comment with timings
						case _ if (extractor.direction == Ignored):
							return next();

						// Assertions
						case Assert:
							clearAssert();
							currentAssert = switch (cast extractor.rest :AssertionKind) {
								case null:
									Sys.println('$l: Invalid assertion "$line"');
									exit(1);
									None;

								case ExpectReached:
									assertionResult(l, !aborted, ExpectReached(l));

								case ExpectUnreachable:
									assertionResult(l, aborted, ExpectUnreachable(l));

								case ExpectFailure: ExpectFailure(l);
								case ExpectSuccess: ExpectSuccess(l);
								case ExpectItemCount: ExpectItemCount(l, extractor.id);
							}

							next();

						// Initialization

						case Root:
							root = extractor.method;
							next();

						case UserConfig:
							userConfig = getData();
							next();

						// TODO: actually use this
						case DisplayServer:
							displayServer = getData();
							next();

						case DisplayArguments:
							displayArguments = getData();
							next();

						case CheckoutGitRef:
							println('$l: > Checkout git ref');
							checkoutGitRef(nextLine(), next);

						case ApplyGitPatch:
							println('$l: > Apply git patch');
							applyGitPatch(next);

						case AddGitUntracked:
							println('$l: > Add untracked files');
							addGitUntracked(next);

						// Direct communication between client and server

						case ServerRequest:
							if (!started) {
								println('$l: repro script not started yet. Use "- start" before sending requests.');
								exit(1);
							}

							if (!aborted) {
								var line = nextLine();
								switch (line.charCodeAt(0)) {
									case '{'.code:
										var data:Dynamic = Json.parse(line);
										serverJsonRequest(l, extractor.id, extractor.method, data, next);

									case _:
										var data:Array<String> = cast Json.parse(line);
										serverRequest(l, extractor.id, extractor.method, data, next);
								}
							} else {
								nextLine();
								next();
							}

						case ServerResponse:
							// var id = extractor.id;
							// var method = extractor.method;
							// Disabled printing for now as it can be confused with actual result from repro...
							// var idDesc = id == null ? '' : ' #$id';
							// var methodDesc = method == null ? '' : ' "$method"';
							// var desc = (id != null || method != null) ? " for" : "";
							// println('$l: < Server response${desc}${idDesc}${methodDesc}');
							// TODO: check against actual result
							nextLine();
							next();

						case ServerError:
							// var id = extractor.id;
							// var method = extractor.method;
							// Disabled printing for now as it can be confused with actual result from repro...
							// var idDesc = id == null ? '' : ' #$id';
							// var methodDesc = method == null ? '' : ' "$method"';
							// if (id == null && method == null) methodDesc = " request";
							// println('$l: < Server error while executing${idDesc}${methodDesc}');
							// TODO: check against actual error
							getFileContent();
							next();

						case CompilationResult:
							// Disabled printing for now as it can be confused with actual result from repro...
							// var fail = extractor.method == "" ? "ok" : "failed";
							// println('$l: < Compilation result: $fail');
							// TODO: check against actual result
							getFileContent();
							next();

						// Editor events

						case DidChangeTextDocument:
							var event:DidChangeTextDocumentParams = getData();
							println('$l: Apply document change to ${event.textDocument.uri.toFsPath().toString()}');
							didChangeTextDocument(event, next);

						case FileCreated:
							var id = extractor.id;
							var event:FileEvent = getData();
							var content = id == 0
								? ""
								: File.getContent(Path.join([path, NEWFILES_DIR, '$id.contents']));

							var path = maybeConvertPath(event.uri.toFsPath().toString());
							FileSystem.createDirectory(Path.directory(path));
							File.saveContent(path, content);
							next();

						case FileDeleted:
							var event:FileEvent = getData();
							var path = maybeConvertPath(event.uri.toFsPath().toString());
							FileSystem.deleteFile(path);
							next();

						// Commands

						case Start:
							start(
								userConfig != null
									? serverJsonRequest.bind(l, 0, "initialize", userConfig, next)
									: next
							);

						case Pause:
							pause(next);

						case Abort:
							aborted = true;
							done();

						case AbortOnFailure:
							abortOnFailure = extractor.id == null || extractor.id == 1;
							next();

						case StepByStep:
							stepping = extractor.id == 1;
							next();

						case DisplayResponse:
							displayNextResponse = true;
							next();

						case Echo:
							println('$l: ${extractor.method}');
							next();

						case entry:
							println('$l: Unhandled entry: $entry');
							exit(1);
					}

				case _:
					trace('$l: Unexpected line:\n$line');
			}
		} catch (e) {
			console.error(e);
			cleanup();
		}
	}

	function clearAssert():Void {
		// Set previous assertion as failed (if any)
		currentAssert = switch (currentAssert) {
			case None: None;
			// TODO: add logs if !silent
			case _: assertionResult(null, false);
		}
	}

	function assertionResult(l:Null<Int>, result:Null<Bool>, ?assert:Assertion):Assertion {
		if (assert == null) assert = currentAssert;

		assertions.set(switch (assert) {
			case ExpectReached(l) | ExpectUnreachable(l) | ExpectFailure(l)
				 | ExpectSuccess(l) | ExpectItemCount(l, _): l;

			case None: throw 'Invalid assertion result';
		}, {
			assert: assert,
			lineApplied: l,
			success: result
		});

		currentAssert = None;
		return currentAssert;
	}

	function cleanup():Void {
		file.close();
		resetGit();
		// No need to close the client, it's not stateful
		if (server != null) server.kill();
	}

	function exit(code:Int = 1):Void {
		cleanup();
		Sys.exit(code);
	}

	function println(s:String):Void if (!aborted && !silent) Sys.println(s);

	function getLine():String {
		lineNumber++;
		return file.readLine();
	}

	function getFileContent():String {
		var next = nextLine();

		if (next == "<<EOF") {
			var ret = new StringBuf();
			while (true) {
				var line = getLine();
				if (line == "EOF") break;
				ret.add(line);
				ret.add("\n");
			}
			return ret.toString();
		}

		return next;
	}

	function nextLine():String {
		// TODO: handle EOF
		while (true) {
			var ret = getLine();
			if (ret == "") continue;
			if (ret.charCodeAt(0) == '#'.code) continue;
			return ret;
		}
	}

	function getData<T:{}>():T
		return cast Json.parse(nextLine());

	function git(args:Rest<String>):String {
		var proc = ChildProcess.spawnSync("git", args.toArray());
		if (proc.status > 0) throw (proc.stderr:Buffer).toString().trim();
		return (proc.stdout:Buffer).toString().trim();
	}

	function checkoutGitRef(ref:String, next:Void->Void):Void {
		gitRef = git("rev-parse", "--abbrev-ref", "HEAD");
		if (gitRef == "HEAD") gitRef = git("rev-parse", "--short", "HEAD");

		if (git("status", "--porcelain").trim() != "") {
			gitStash = true;
			git("stash", "save", "--include-untracked", "Stash before repro");
		}

		git("checkout", ref);
		next();
	}

	function applyGitPatch(next:Void->Void):Void {
		git("apply", "--allow-empty", Path.join([path, REPRO_PATCHFILE]));
		next();
	}

	function addGitUntracked(next:Void->Void):Void {
		var untracked = Path.join([path, UNTRACKED_DIR]);

		function copyUntracked(root:String) {
			var dir = Path.join([untracked, root]);
			for (entry in FileSystem.readDirectory(dir)) {
				var entryPath = Path.join([untracked, root, entry]);

				if (FileSystem.isDirectory(entryPath)) {
					copyUntracked(Path.join([root, entry]));
				} else {
					var target = Path.join([root, entry]);
					var targetDir = Path.directory(target);

					if (targetDir != "" && !FileSystem.exists(targetDir))
						FileSystem.createDirectory(targetDir);

					File.saveContent(target, File.getContent(entryPath));
				}
			}
		}

		copyUntracked(".");
		next();
	}

	function resetGit():Void {
		if (gitRef == null) return;
		git("clean", "-f", "-d");
		git("reset", "--hard");
		git("checkout", gitRef);
		if (gitStash) git("stash", "pop");
	}

	function maybeConvertPath(a:String):String {
		var fileparam = '"params":{"file":"';
		if (a.contains('$fileparam$root')) return a.replace('$fileparam$root', '$fileparam./');

		if (a.charCodeAt(0) == "/".code) {
			if (a.startsWith(root)) return "./" + a.substr(root.length);
			throw 'Absolute path outside root not handled yet ($a)';
		}

		// TODO: clean that
		if (a.startsWith("--cwd /")) {
			if (a.startsWith("--cwd " + root)) return "--cwd ./" + a.substr("--cwd ".length + root.length);
			throw 'Absolute path outside root not handled yet ($a)';
		}

		return a;
	}

	function serverJsonRequest(
		l:Int,
		id:Null<Int>,
		method:String,
		params:Dynamic,
		cb:Void->Void
	):Void {
		var args = displayArguments.concat([
			"--display",
			Json.stringify({method: method, id: id, params: params})
		]);
		serverRequest(l, id, method, args, next);
	}

	function serverRequest(
		l:Int,
		id:Null<Int>,
		request:String,
		params:Array<String>,
		cb:Void->Void
	):Void {
		var next = function() {
			clearAssert();

			if (stepping) pause(cb);
			else cb();
		}

		var idDesc = id == null ? '' : ' #$id';
		println('$l: > Server request$idDesc "$request"');

		params = params.map(maybeConvertPath);
		// trace(params);

		client.rawRequest(
			params,
			res -> {
				var hasError = res.hasError;
				var out:String = res.stderr.toString();

				// TODO: compare with serverResponse
				switch (request) {
					case "compilation":
						if (hasError) println('$l: => Compilation error:\n' + out.trim());
						else if (displayNextResponse) println(out.trim());

					case _:
						switch (extractResult(out)) {
							case JsonResult(res):
								switch (request) {
									case "display/completion":
										var res:CompletionResult = cast res.result;
										if (res.result == null) hasError = true;
										else {
											hasError = false;
											var nbItems = res.result.items.length;

											if (displayNextResponse) {
												println('$l => Completion request returned $nbItems items');
											}

											switch (currentAssert) {
												case ExpectItemCount(_, c): assertionResult(l, c == nbItems);
												case _:
											}
										}

										if (hasError) println('$l: => Completion request failed');

									case "server/contexts" if (displayNextResponse):
										var contexts:Array<HaxeServerContext> = cast res.result.result;
										for (c in contexts) {
											println('  ${c.index} ${c.desc} (${c.platform}, ${c.defines.length} defines)');
											println('    signature: ${c.signature}');
											// println('    defines: ${c.defines.map(d -> d.key).join(", ")}');
										}

									// TODO: other special case handling

									case _:
										if (hasError || displayNextResponse) {
											var hasError = hasError ? "(has error)" : "";
											println('$l: => Server response: $hasError');
										}

										if (displayNextResponse) println(Std.string(res));
								}

							case Raw(out):
								if (hasError || displayNextResponse) {
									var hasError = res.hasError ? "(has error)" : "";
									println('$l: => Server response: $hasError');
								}

								if (displayNextResponse) println(out);

							case Empty:
								if (request == "display/completion") hasError = true;
								if (hasError || displayNextResponse) println('$l: => Empty server response');
						}
				}

				switch (currentAssert) {
					case ExpectFailure(_): assertionResult(l, hasError);
					case ExpectSuccess(_): assertionResult(l, !hasError);
					case _:
				}

				if (displayNextResponse) displayNextResponse = false;
				if (hasError && abortOnFailure) {
					println('Failure detected, aborting rest of script.');
					aborted = true;
				}

				// TODO: make sure we use the actual display request order
				// (including overlapping requests if any) instead of these
				// compilation flags
				#if haxeserver.displayrequests_wait
					#if haxeserver.displayrequests_delay
					haxe.Timer.delay(next, Std.parseInt(haxe.macro.Compiler.getDefine("haxeserver.displayrequests_delay")));
					#else
					next();
					#end
				#end
			},
			err -> throw err
		);

		// Continue immediately?
		#if !haxeserver.displayrequests_wait
			#if haxeserver.displayrequests_delay
			haxe.Timer.delay(next, Std.parseInt(haxe.macro.Compiler.getDefine("haxeserver.displayrequests_delay")));
			#else
			next();
			#end
		#end
	}

	// TODO: response type
	function serverResponse(id:Null<Int>, request:String, result:Any):Void {
		// tasks.push(function(next:Next):Void {
		// 	trace('serverResponse #$id: "$request"');
		// 	next(Success);
		// });
	}

	function extractResult<T:{}>(out:String):ResponseKind<T> {
		var lines = out.split("\n");
		var last = lines.pop();
		switch [lines.length, last] {
			case [1, ""]:
				var json = try Json.parse(lines[0]) catch(_) null;
				return JsonResult(json);

			case [n, _]:
				var out = lines.join("\n") + (last == "" ? "" : '\n$last');
				return out == "" ? Empty : Raw(out);
		}
	}

	function didChangeTextDocument(event:DidChangeTextDocumentParams, next:Void->Void):Void {
		var path = maybeConvertPath(event.textDocument.uri.toFsPath().toString());
		var content = File.getContent(path);
		var doc = new HxTextDocument(event.textDocument.uri, "", 0, content);
		doc.update(event.contentChanges, event.textDocument.version);
		File.saveContent(path, doc.content);
		next();
	}
}

typedef AssertionItem = {
	var assert:Assertion;
	@:optional var lineApplied:Int;
	@:optional var success:Bool;
}

enum Assertion {
	None;
	ExpectReached(line:Int);
	ExpectUnreachable(line:Int);
	ExpectFailure(line:Int);
	ExpectSuccess(line:Int);
	ExpectItemCount(line:Int, count:Int);
}

enum abstract AssertionKind(String) {
	var ExpectReached = "true";
	var ExpectUnreachable = "false";
	var ExpectFailure = "fail";
	var ExpectSuccess = "success";
	var ExpectItemCount = "items";
}

enum ResponseKind<T:{}> {
	JsonResult(json:Response<T>);
	Raw(out:String);
	Empty;
}
