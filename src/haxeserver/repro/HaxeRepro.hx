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

import haxeserver.process.HaxeServerProcessConnect;
import haxeLanguageServer.Configuration;
import haxeLanguageServer.DisplayServerConfig;
import haxeLanguageServer.documents.HxTextDocument;
import languageServerProtocol.protocol.Protocol.DidChangeTextDocumentParams;
import languageServerProtocol.textdocument.TextDocument.DocumentUri;
import languageServerProtocol.textdocument.TextDocument.TextDocumentContentChangeEvent;

// TODO: open issue and/or improve error
// Module js.Node does not define type console
// import js.Node.console.error;

using StringTools;
using haxeLanguageServer.extensions.DocumentUriExtensions;
using haxeserver.repro.HaxeRepro;

class HaxeRepro {
	static inline var REPRO_DEFINE = 'haxeserver.repro';
	static inline var REPRO_LOGFILE = 'repro.log';
	static inline var REPRO_PATCHFILE = 'status.patch';

	var userConfig:UserConfig;
	var displayServer:DisplayServerConfig;
	var displayArguments:Array<String>;

	var file:FileInput;
	var server:ChildProcessObject;
	var client:HaxeServerAsync;

	var path:String;
	var gitRef:String;
	var logfile(get, never):String;
	inline function get_logfile():String return Path.join([path, REPRO_LOGFILE]);

	static var extractor = ~/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) (>|<) (\w+)(?: #(\d+))?(?: "([^"]+)")?$/;

	public static function main() {
		var args = Sys.args();
		if (args.length == 0) {
			// TODO: print proper help message
		}

		var path = args.shift();
		if (!FileSystem.exists(path) || !FileSystem.isDirectory(path)) {
			console.error('Invalid dump path provided, skipping repro.');
			Sys.exit(1);
		}

		var logfile = Path.join([path, REPRO_LOGFILE]);
		if (!FileSystem.exists(logfile) || FileSystem.isDirectory(logfile)) {
			console.error('Invalid dump path provided, skipping repro.');
			Sys.exit(1);
		}

		new HaxeRepro(path);
	}

	function new(path) {
		this.path = path;
		this.file = File.read(logfile);
		next();
	}

	function start(done:Void->Void):Void {
		// TODO: only if ready
		server = ChildProcess.spawn("haxe", ["--wait", "7001"]);
		var process = new HaxeServerProcessConnect("haxe", 7001, displayArguments);
		client = new HaxeServerAsync(() -> process);
		done();
	}

	function cleanup() {
		resetGit();
		if (client != null) client.stop();
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
			switch (line.charCodeAt(0)) {
				case '#'.code: return next();

				// Surely we won't be running this for 1000+ years
				case '2'.code if (extractor.match(line)):
					final get = extractor.matched;
					final entry = (cast get(3) :ReproEntry);

					// TODO: add proper (and optional) logging
					// Sys.println(entry);

					switch (entry) {
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
							var id = get(4) == null ? null : Std.parseInt(get(4));
							var method = get(5);
							displayRequest(id, method, file.getData(), next);

						case ServerResponse:
							var id = get(4);
							var method = get(5);
							if (id == null) Sys.println('< Got server response for $method');
							else Sys.println('< Got server response for #$id $method');
							file.readLine();
							next();

						case DidChangeTextDocument:
							var event:DidChangeTextDocumentParams = file.getData();
							Sys.println('Apply document change to ${event.textDocument.uri.toFsPath().toString()}');
							didChangeTextDocument(event, next);

						case entry:
							// TODO: error
							// for (i in 1...6) trace(get(i));
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
		git("stash", "pop");
	}

	function displayRequest(
		id:Null<Int>,
		request:String,
		params:Array<String>,
		next:Void->Void
	):Void {
		switch [id, request] {
			case [null, _]: Sys.println('> $request');
			case _: Sys.println('> #$id Display request $request');
		}

		client.rawRequest(
			params,
			res -> {
				// TODO: compare with serverResponse
				// trace(res);
				next();
			},
			err -> throw err
		);
	}

	// TODO: response type
	function serverResponse(id:Null<Int>, request:String, result:Any):Void {
		// tasks.push(function(next:Next):Void {
		// 	trace('serverResponse #$id: "$request"');
		// 	next(Success);
		// });
	}

	function didChangeTextDocument(event:DidChangeTextDocumentParams, next:Void->Void):Void {
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
	var UserConfig = "userConfig";
	var DisplayServer = "displayServer";
	var DisplayArguments = "displayArguments";
	var CheckoutGitRef = "checkoutGitRef";
	var ApplyGitPatch = "applyGitPatch";
	var AddGitUntracked = "addGitUntracked";

	// Direct communication between client and server
	var DisplayRequest = "displayRequest";
	var ServerResponse = "serverResponse";

	// Editor events
	var DidChangeTextDocument = "didChangeTextDocument";
	var FileCreated = "fileCreated";
	var FileDeleted = "fileDeleted";
}
