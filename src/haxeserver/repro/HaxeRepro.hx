package haxeserver.repro;

import haxe.Json;
import haxe.Rest;
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

// TODO: open issue and/or improve error
// Module js.Node does not define type console
// import js.Node.console.error;

using StringTools;
using haxeLanguageServer.extensions.DocumentUriExtensions;
using haxeserver.repro.HaxeRepro;

class HaxeRepro {
	static inline var REPRO_PATCHFILE = 'status.patch';

	var userConfig:UserConfig;
	var displayServer:DisplayServerConfig;
	var displayArguments:Array<String>;

	var port:Int = 7000;
	var file:FileInput;
	var server:ChildProcessObject;
	var client:HaxeServerAsync;

	var path:String;
	var root:String = "./";
	var filename:String = "repro.log";
	var gitRef:String;
	var logfile(get, never):String;
	inline function get_logfile():String return Path.join([path, filename]);

	static var extractor:Extractor = ~/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (>|<) (\w+)(?: #(\d+))?(?: "([^"]+)")?$/;

	public static function main() new HaxeRepro();

	function new() {
		var handler = hxargs.Args.generate([
			@doc("Path to the repro dump directory (mandatory)")
			["--path"] => p -> path = p,
			@doc("Log file to use in the dump directory. Default is repro.log")
			["--file"] => f -> filename = f,
			@doc("Port to use internally for haxe server. Should *not* refer to an existing server. Default is 7000")
			["--port"] => p -> port = p,
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
			console.error('Invalid dump path provided, skipping repro.');
			Sys.exit(1);
		}

		var logfile = Path.join([path, filename]);
		if (!FileSystem.exists(logfile) || FileSystem.isDirectory(logfile)) {
			console.error('Invalid dump path provided, skipping repro.');
			Sys.exit(1);
		}

		this.file = File.read(logfile);
		next();
	}

	function start(done:Void->Void):Void {
		server = ChildProcess.spawn("haxe", ["--wait", Std.string(port)]);
		var process = new HaxeServerProcessConnect("haxe", port, []);
		client = new HaxeServerAsync(() -> process);
		done();
	}

	function cleanup() {
		resetGit();
		// No need to close the client, it's not stateful
		if (server != null) server.kill();

	}

	function next() {
		var next = Node.process.nextTick.bind(next, []);

		if (file.eof()) {
			Sys.println('Done.');
			return cleanup();
		}

		var line = file.readLine();
		if (line == "") return next();

		try {
			// TODO: add support for "breakpoints" (more like pause points...)
			switch (line.charCodeAt(0)) {
				case '#'.code: return next();

				// Surely we won't be running this for 1000+ years
				case '2'.code if (extractor.match(line)):
					switch (extractor.entry) {
						case Root:
							root = extractor.method;
							next();

						// TODO: actually use this
						case UserConfig:
							userConfig = file.getData();
							next();

						// TODO: actually use this
						case DisplayServer:
							displayServer = file.getData();
							next();

						case DisplayArguments:
							displayArguments = file.getData();
							// TODO: should happen **after** git operations
							// (change in haxe lsp)
							start(next);

						case CheckoutGitRef:
							Sys.println('> Checkout git ref');
							checkoutGitRef(file.readLine(), next);

						case ApplyGitPatch:
							Sys.println('> Apply git patch');
							applyGitPatch(next);

						case AddGitUntracked:
							Sys.println('> Add untracked files');
							addGitUntracked(next);

						case DisplayRequest:
							displayRequest(extractor.id, extractor.method, file.getData(), next);

						case ServerResponse:
							var id = extractor.id;
							var method = extractor.method;
							if (id == null) Sys.println('< Server response for $method');
							else Sys.println('< Server response for #$id $method');
							// TODO: check against actual result
							file.readLine();
							next();

						case CompilationResult:
							var fail = extractor.method;
							Sys.println('< Compilation result: ${fail == "" ? "ok" : "failed"}');
							// TODO: check against new result
							while (file.readLine() != "EOF") {}
							next();

						case DidChangeTextDocument:
							var event:DidChangeTextDocumentParams = file.getData();
							Sys.println('Apply document change to ${event.textDocument.uri.toFsPath().toString()}');
							didChangeTextDocument(event, next);

						case entry:
							throw 'Unhandled entry: $entry';
					}

				case _:
					trace('Unexpected line:\n$line');
			}
		} catch (e) {
			console.error(e);
			cleanup();
		}
	}

	static function getData<T:{}>(file:FileInput):T
		return cast Json.parse(file.readLine());

	function git(args:Rest<String>):String {
		var proc = ChildProcess.spawnSync("git", args.toArray());
		if (proc.status > 0) throw (proc.stderr:Buffer).toString().trim();
		return (proc.stdout:Buffer).toString().trim();
	}

	function checkoutGitRef(ref:String, next:Void->Void):Void {
		gitRef = git("rev-parse", "--abbrev-ref", "HEAD");
		if (gitRef == "HEAD") gitRef = git("rev-parse", "--short", "HEAD");

		git("stash", "save", "--include-untracked", "Stash before repro");
		git("checkout", ref);
		next();
	}

	function applyGitPatch(next:Void->Void):Void {
		git("apply", "--allow-empty", Path.join([path, REPRO_PATCHFILE]));
		next();
	}

	function addGitUntracked(next:Void->Void):Void {
		trace('TODO: apply untracked');
		next();
	}

	function resetGit():Void {
		if (gitRef == null) return;
		git("clean", "-f", "-d");
		git("reset", "--hard");
		git("checkout", gitRef);
		try git("stash", "pop") catch(_) {}
	}

	function maybeConvertPath(a:String):String {
		var fileparam = '"params":{"file":"';
		if (a.contains('$fileparam$root')) return a.replace('$fileparam$root', '$fileparam./');

		if (a.charCodeAt(0) == "/".code) {
			if (a.startsWith(root)) return "./" + a.substr(root.length);
			throw 'Absolute path outside root not handled yet ($a)';
		}

		return a;
	}

	function displayRequest(
		id:Null<Int>,
		request:String,
		params:Array<String>,
		next:Void->Void
	):Void {
		switch [id, request] {
			case [null, _]: Sys.println('> $request');
			case _: Sys.println('> Display request $request');
			// case _: Sys.println('> #$id Display request $request');
		}

		params = params.map(maybeConvertPath);
		// trace(params);

		client.rawRequest(
			params,
			res -> {
				// TODO: compare with serverResponse
				// trace(res.hasError, res.stderr.trim());
				switch (request) {
					case "display/completion":
						// trace(res);
						// trace(res.stderr.toString());
						// var result = Json.parse(res.stderr.toString().replace("\n", "")).result.result;
						if (res.stderr.toString().indexOf('"result":{"items"') == -1)
							Sys.println('=> Completion request failed');
						// else trace('Completion request returned ${result.length} elements');

					case "compilation":
						if (res.hasError) Sys.println('=> Error:\n' + res.stderr.toString().trim());
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

	function didChangeTextDocument(event:DidChangeTextDocumentParams, next:Void->Void):Void {
		// TODO: map absolute path to relative paths
		var path = event.textDocument.uri.toFsPath().toString();
		var content = File.getContent(path);
		var doc = new HxTextDocument(event.textDocument.uri, "", 0, content);
		doc.update(event.contentChanges, event.textDocument.version);
		File.saveContent(path, doc.content);
		next();
	}
}

enum abstract ReproEntry(String) {
	// Initialization
	var Root = "root";
	var UserConfig = "userConfig";
	var DisplayServer = "displayServer";
	var DisplayArguments = "displayArguments";
	var CheckoutGitRef = "checkoutGitRef";
	var ApplyGitPatch = "applyGitPatch";
	var AddGitUntracked = "addGitUntracked";

	// Direct communication between client and server
	var DisplayRequest = "displayRequest";
	var ServerResponse = "serverResponse";
	var CompilationResult = "compilationResult";

	// Editor events
	var DidChangeTextDocument = "didChangeTextDocument";
	var FileCreated = "fileCreated";
	var FileDeleted = "fileDeleted";
}

@:forward(match)
abstract Extractor(EReg) from EReg {
	public var entry(get, never):ReproEntry;
	function get_entry():ReproEntry return cast this.matched(3);

	public var id(get, never):Null<Int>;
	function get_id():Null<Int> {
		var raw = this.matched(4);
		if (raw == null) return null;
		return Std.parseInt(raw);
	}

	public var method(get, never):String;
	function get_method():String return this.matched(5);
}
