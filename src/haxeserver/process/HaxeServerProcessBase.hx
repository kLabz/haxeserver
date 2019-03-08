package haxeserver.process;

import haxe.io.BytesOutput;
import haxe.io.BytesBuffer;
import haxe.io.Bytes;

class HaxeServerProcessBase {
	function processResult(result:Bytes, stdout:Bytes) {
		var buf = new StringBuf();
		var currentLine = new StringBuf();
		var prints = [];
		var newLine = true;
		var hasError = false;
		var inPrint = false;
		function commitLine() {
			var line = currentLine.toString();
			if (inPrint) {
				prints.push(line);
				inPrint = false;
			} else {
				buf.add(line);
			}
			currentLine = new StringBuf();
		}
		inline function add(byte:Int) {
			currentLine.addChar(byte);
		}
		for (offset in 0...result.length) {
			var byte = result.get(offset);
			switch (byte) {
				case "\n".code:
					add(byte);
					commitLine();
					newLine = true;
				case 0x01:
					inPrint = true;
				case 0x02:
					hasError = true;
				case _:
					add(byte);
			}
		}
		commitLine();
		return {
			hasError: hasError,
			prints: prints,
			stdout: stdout.getString(0, stdout.length),
			stderr: buf.toString()
		}
	}

	function prepareInput(arguments:Array<String>, ?stdin:Bytes) {
		var out = new BytesOutput();
		for (argument in arguments) {
			out.writeString(argument);
			out.writeByte("\n".code);
		}
		if (stdin != null) {
			out.writeByte(1);
			out.write(stdin);
		}
		var buf = new BytesBuffer();
		buf.addInt32(out.length);
		buf.add(out.getBytes());
		return buf.getBytes();
	}
}