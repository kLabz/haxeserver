package haxeserver.repro;

import haxe.Json;
import haxe.Rest;
import haxe.display.Display;
import haxe.display.Protocol;
import haxe.display.Server;
import haxe.io.Path;
import js.Node;
import js.Node.console;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileInput;
import sys.io.FileOutput;

import haxeserver.process.HaxeServerProcessConnect;

using StringTools;
using haxeserver.repro.HaxeRepro;

class ReduceRecording {
	// Configuration
	var path:String;
	// TODO: might need path_in and path_out so that file events from cut part
	// can be replaced with git stash + untracked files
	var filename_in:String = "repro.log";
	var filename_out:String = "repro-min.log";

	// Reducing options
	var skipUntil:Int = 0;
	var keepInvalidate:Bool = false;
	var keepCompletion:Bool = true;
	var keepDiagnostics:Bool = true;
	var keepCompletionItemResolve:Bool = false;

	// State
	var lineNumber:Int = 0;
	var invalidated:Array<String> = [];
	var skipping(get, never):Bool;
	function get_skipping():Bool return lineNumber < skipUntil;

	var file_in:FileInput;
	var file_out:FileOutput;
	var extractor = Extractor.init();

	public static function main() new ReduceRecording();

	function new() {
		var overwrite:Bool = false;

		var handler = hxargs.Args.generate([
			@doc("Path to the repro recording directory (mandatory)")
			["--path"] => p -> path = p,
			@doc("Log file to use in the recording directory. Default is `repro.log`.")
			["--file-in"] => f -> filename_in = f,
			@doc("Log file to generate in the recording directory. Default is `repro-min.log`.")
			["--file-out"] => f -> filename_out = f,
			@doc("Skip all non-essential lines before this one.")
			["--skip-until"] => s -> skipUntil = s,
			@doc("Do not try to optimize 'server/invalidate' requests.")
			["--keep-server-invalidate"] => () -> keepInvalidate = true,
			@doc("Do not remove 'display/completionItem/resolve' requests.")
			["--keep-completionitem-resolve"] => () -> keepCompletionItemResolve = true,
			@doc("Remove completion requests.")
			["--no-completion"] => () -> {
				keepCompletion = false;
				keepCompletionItemResolve = false;
			},
			@doc("Remove diagnostics requests.")
			["--no-diagnostics"] => () -> keepDiagnostics = false,
			@doc("Overwrite target file if exists.")
			["--overwrite"] => () -> overwrite = true,
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
			console.error('Invalid recording path provided, aborting.');
			Sys.exit(1);
		}

		// TODO: factorize with below
		var filepath = Path.join([path, filename_in]);
		if (!FileSystem.exists(filepath) || FileSystem.isDirectory(filepath)) {
			console.error('Invalid recording file provided, aborting.');
			Sys.exit(1);
		}
		this.file_in = File.read(filepath);

		var filepath = Path.join([path, filename_out]);
		if (FileSystem.exists(filepath) && !overwrite) {
			console.error('Target file exists, aborting.');
			Sys.exit(1);
		}
		this.file_out = File.write(filepath);

		addLine('# Reduced from ${filename_in}');
		next();
	}

	function done():Void {
		cleanup();
	}

	function next() {
		var next = Node.process.nextTick.bind(next, []);
		if (file_in.eof()) return done();

		var line = getLine(false);
		if (line == "") return next();
		var l = lineNumber;

		try {
			switch (line.charCodeAt(0)) {
				case '#'.code:
					// TODO: addline if not currently skipping?
					return next();

				case _ if (extractor.match(line)):
					// trace(l, extractor.entry);

					switch (extractor.entry) {
						// Comment with timings
						case _ if (extractor.direction == Ignored):
							if (!skipping) addLine(line);
							next();

						// Assertions
						// We should probably avoid asserts and command _before_ reducing anyway...
						case Assert:
							if (!skipping) addLine(line);
							next();

						// Initialization

						case UserConfig | DisplayServer | DisplayArguments | CheckoutGitRef:
							addLine(line);
							getLine(true);
							next();


						case Root | ApplyGitPatch | AddGitUntracked:
							addLine(line);
							next();

						// Direct communication between client and server

						case ServerRequest:
							var data = nextLine(false);
							var skipping = switch extractor.method {
								case "compilation" | "cache build" | "server/readClassPaths":
									invalidated = [];
									false;

								case "@diagnostics" if (!keepDiagnostics):
									true;

								case "display/completion" if (!keepCompletion):
									true;

								case "display/completionItem/resolve"
								if (!keepCompletionItemResolve):
									true;

								case "server/invalidate"
								if (!skipping && !keepInvalidate && data.charCodeAt(0) == '['.code):
									var data:Array<String> = cast Json.parse(data);
									var rpc = Json.parse(data.pop());
									var file = rpc.params.file;

									if (Lambda.has(invalidated, file)) true;
									else {
										invalidated.push(file);
										false;
									}

								case _: skipping;
							}

							if (!skipping) {
								addLine(line);
								addLine(data);
							}

							next();

						case ServerResponse:
							nextLine(false);
							next();

						case ServerError | CompilationResult:
							getFileContent(false);
							next();

						// Editor events

						// TODO: if we're currently skipping (from beginning of
						// recording), apply all file events and update
						// stash/untracked at the end of skipped section to
						// replace file events.
						case DidChangeTextDocument | FileCreated | FileDeleted:
							addLine(line);
							getLine(true);
							next();

						// Commands

						// We shouldn't really add commands before reducing
						case Start | Pause | Abort | AbortOnFailure | StepByStep | DisplayResponse | Echo:
							addLine(line);
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

	function cleanup():Void {
		file_in.close();
		file_out.close();
	}

	inline function exit(code:Int = 1):Void Sys.exit(code);
	inline function println(s:String):Void Sys.println(s);

	function getLine(add:Bool):String {
		lineNumber++;
		var ret = file_in.readLine();
		if (add) addLine(ret);
		return ret;
	}

	function addLine(line:String):Void {
		file_out.writeString(line + '\n');
	}

	function getFileContent(add:Bool):String {
		var next = nextLine(add);

		if (next == "<<EOF") {
			var ret = new StringBuf();
			while (true) {
				var line = getLine(add);
				if (line == "EOF") break;
				ret.add(line);
				ret.add("\n");
			}
			return ret.toString();
		}

		return next;
	}

	function nextLine(add:Bool):String {
		// TODO: handle EOF
		while (true) {
			var ret = getLine(false);
			if (ret == "") continue;
			if (add) addLine(ret);
			if (ret.charCodeAt(0) == '#'.code) continue;
			return ret;
		}
	}
}
