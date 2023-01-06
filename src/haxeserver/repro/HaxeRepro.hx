package haxeserver.repro;

import sys.io.Process;
import haxe.DynamicAccess;
import haxe.Json;
import haxe.display.Server.ConfigurePrintParams;
import haxe.extern.EitherType;
import haxe.io.Path;
import js.Node.console;
import sys.FileSystem;
import sys.io.File;
import sys.io.FileInput;

import haxeserver.process.IHaxeServerProcess;
import haxeserver.process.HaxeServerProcessNode;

// TODO: open issue and/or improve error
// Module js.Node does not define type console
// import js.Node.console.error;

using haxeserver.repro.HaxeRepro;

class HaxeRepro {
	static inline var REPRO_DEFINE = 'haxeserver.repro';
	static inline var REPRO_LOGFILE = 'repro.log';
	static inline var REPRO_PATCHFILE = 'status.patch';

	var userConfig:UserConfig;
	var displayServer:DisplayServerConfig;
	var displayArguments:Array<String>;

	var file:FileInput;
	var process:IHaxeServerProcess;
	var server:HaxeServerAsync;

	var path:String;
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
		// TODO: make sure to cleanup when done
		process = new HaxeServerProcessNode("haxe", displayArguments, done);
		server = new HaxeServerAsync(() -> process);
	}

	function next() {
		if (file.eof()) return;
		var line = file.readLine();
		if (line == "") return next();

		switch (line.charCodeAt(0)) {
			case '#'.code: return next();

			// Surely we won't be running this for 1000+ years
			case '2'.code if (extractor.match(line)):
				final get = extractor.matched;
				final entry = (cast get(3) :ReproEntry);

				// TODO: add proper (and optional) logging
				trace(entry);

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
						checkoutGitRef(file.readLine(), next);

					case ApplyGitPatch:
						applyGitPatch(next);

					case AddGitUntracked:
						addGitUntracked(next);


					case entry:
						trace(entry);
						// TODO: error
						for (i in 1...6) trace(get(i));
				}

			case _:
				trace('Unexpected line:\n$line');
		}
	}

	static function getData<T:{}>(file:FileInput):T
		return cast Json.parse(file.readLine());

	function git(args:Array<String>):Void {
		var proc = new Process("git", args);
		if (proc.exitCode(true) > 0) throw proc.stderr.readAll();
	}

	function checkoutGitRef(ref:String, next:Void->Void):Void {
		git(["stash", "save", "--include-untracked", "Stash before repro"]);
		git(["checkout", ref]);
		next();
	}

	function applyGitPatch(next:Void->Void):Void {
		git(["apply", "--allow-empty", Path.join([path, REPRO_PATCHFILE])]);
		next();
	}

	function addGitUntracked(next:Void->Void):Void {
		trace('TODO: apply untracked');
		next();
	}

	function displayRequest(id:Null<Int>, request:String, params:Array<String>):Void {
		// tasks.push(function(next:Next):Void {
		// 	trace('displayRequest #$id: "$request"');
		// 	next(Success);
		// });
	}

	// TODO: response type
	function serverResponse(id:Null<Int>, request:String, result:Any):Void {
		// tasks.push(function(next:Next):Void {
		// 	trace('serverResponse #$id: "$request"');
		// 	next(Success);
		// });
	}

	// TODO: event type
	function didChangeTextDocument(event:{
		textDocument: {
			version: Int,
			uri: String,
		},
		contentChanges: Array<Dynamic>
	}):Void {
		// tasks.push(function(next:Next):Void {
		// 	trace('TODO: didChangeTextDocument event');
		// 	next(Success);
		// });
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

// TODO: use types from haxe LSP

private typedef DisplayServerConfig = {
	var path:String;
	var env:DynamicAccess<String>;
	var arguments:Array<String>;
	var useSocket:Bool;
	var print:ConfigurePrintParams;
}

private typedef UserConfig = {
	var enableCodeLens:Bool;
	var enableDiagnostics:Bool;
	var enableServerView:Bool;
	var enableSignatureHelpDocumentation:Bool;
	var diagnosticsPathFilter:String;
	var displayPort:EitherType<Int, String>;
	var buildCompletionCache:Bool;
	var enableCompletionCacheWarning:Bool;
	var useLegacyCompletion:Bool;
	var codeGeneration:CodeGenerationConfig;
	var exclude:Array<String>;
	var postfixCompletion:PostfixCompletionConfig;
	var importsSortOrder:ImportsSortOrderConfig;
	var maxCompletionItems:Int;
	var renameSourceFolders:Array<String>;
	var inlayHints:InlayHintConfig;
	var enableServerDump:Bool;
	var serverDumpPath:String;
	var serverDumpSourceMode:ServerDumpSourceMode;
}

private typedef InlayHintConfig = {
	var variableTypes:Bool;
	var parameterNames:Bool;
	var parameterTypes:Bool;
	var functionReturnTypes:Bool;
	var conditionals:Bool;
}

private typedef PostfixCompletionConfig = {
	var level:PostfixCompletionLevel;
}

private typedef CodeGenerationConfig = {
	var functions:FunctionGenerationConfig;
	var imports:ImportGenerationConfig;
	var switch_:SwitchGenerationConfig;
}

private typedef SwitchGenerationConfig = {
	var parentheses:Bool;
}

private typedef ImportGenerationConfig = {
	var enableAutoImports:Bool;
	var style:ImportStyle;
}

private typedef FunctionGenerationConfig = {
	var anonymous:FunctionFormattingConfig;
	var field:FunctionFormattingConfig;
}

private typedef FunctionFormattingConfig = {
	var argumentTypeHints:Bool;
	var returnTypeHint:ReturnTypeHintOption;
	var useArrowSyntax:Bool;
	var placeOpenBraceOnNewLine:Bool;
	var explicitPublic:Bool;
	var explicitPrivate:Bool;
	var explicitNull:Bool;
}

private enum abstract ReturnTypeHintOption(String) from String {
	final Always = "always";
	final Never = "never";
	final NonVoid = "non-void";
}

private enum abstract PostfixCompletionLevel(String) from String {
	final Full = "full";
	final Filtered = "filtered";
	final Off = "off";
}

private enum abstract ServerDumpSourceMode(String) from String {
	var SourceFiles;
	var GitStatus;
}

private enum abstract ImportsSortOrderConfig(String) from String {
	final AllAlphabetical = "all-alphabetical";
	final StdlibThenLibsThenProject = "stdlib -> libs -> project";
	final NonProjectThenProject = "non-project -> project";
}

private enum abstract ImportStyle(String) from String {
	final Module = "module";
	final Type = "type";
}
