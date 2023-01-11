package haxeserver.repro;

@:forward(match)
abstract Extractor(EReg) from EReg {
	private function new(r:EReg) this = r;
	public static function init():Extractor
		return new Extractor(
			~/^(?:\+(\d+(?:\.\d+)?)s )?(>|<|-) (\w+)(?: (\d+))?(?: "([^"]+)")?(.*)$/
		);

	public var delta(get, never):Null<Float>;
	function get_delta():Null<Float> {
		var raw = this.matched(1);
		if (raw == null) return null;
		return Std.parseFloat(raw);
	}

	public var direction(get, never):ComDirection;
	function get_direction():ComDirection return cast this.matched(2);

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

	public var rest(get, never):String;
	function get_rest():String return this.matched(6);
}
