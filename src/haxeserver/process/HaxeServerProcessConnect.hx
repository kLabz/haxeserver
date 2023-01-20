package haxeserver.process;

import haxe.io.Eof;
import haxe.io.BytesBuffer;
import haxe.io.BytesOutput;
import haxe.io.Bytes;

#if nodejs
import js.node.Buffer;
import js.node.ChildProcess;
#else
import sys.io.Process;
#end

#if (!sys && !nodejs)
#error "HaxeServerProcess is only supported on sys targets"
#end

/**
	Executes requests with `<HAXE_CMD> --conenct <PORT>`.
	The haxe server process has to be started manually prior to executing requests.
**/
class HaxeServerProcessConnect implements IHaxeServerProcess {
	var baseArguments:Array<String>;
	var haxeCmd:String;

	public function new(haxeCmd:String, port:Int, baseArguments:Array<String>) {
		this.haxeCmd = haxeCmd;
		this.baseArguments = ['--connect', '$port'].concat(baseArguments);
	}

	public function isAsynchronous() {
		return false;
	}

	/**
		Makes a request to the Haxe compilation server with the given `arguments`.
	**/
	public function request(arguments:Array<String>, ?stdin:Bytes, callback:HaxeServerRequestResult->Void, errback:String->Void) {
		#if nodejs
		var p = ChildProcess.spawnSync(haxeCmd, baseArguments.concat(arguments));
		// TODO: handle stdin
		var stdout = (p.stdout:Buffer).hxToBytes();
		var stderr = (p.stderr:Buffer).hxToBytes();
		var exitCode = p.status;

		#else
		var p = new Process(haxeCmd, baseArguments.concat(arguments));
		if (stdin != null) {
			p.stdin.writeInt32(stdin.length + 1);
			p.stdin.writeByte(1);
			p.stdin.write(stdin);
		}
		var stdout = p.stdout.readAll();
		var stderr = p.stderr.readAll();
		var exitCode = p.exitCode();
		p.close();
		#end
		callback({
			hasError: exitCode != 0,
			stdout: stdout.toString(),
			stderr: stderr.toString(),
			stderrRaw: stderr,
			prints: []
		});
	}

	/**
		Closes the Haxe compilation server process. No other methods on `this`
		instance should be used afterwards.

		The `graceful` argument has no effect on this kind of process. If
		`callback` is given, it is called immediately after closing the process.
	**/
	public function close(graceful:Bool = true, ?callback:() -> Void) {
		if (callback != null) {
			callback();
		}
	}
}
