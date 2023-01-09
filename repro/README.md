# Repro tool - common setup

Dependencies (in haxeserver root):
```
haxelib newrepo
haxelib install --always install.hxml
```

Build repro.js with
```
haxe repro.hxml
```

Choose a port that is usually free; making sure a crash of the repro tool didn't
leave the server running is not part of the tool yet, and it's not checking if
port was free atm either so you might have to handle that part yourself for now
if needed. Default port is 7000.

## X redefined from X repro

Dependencies can be installed there with install.hxml, but no dependency is
needed here that are not already included in repro tool dependencies.

### 1st repro - Get initial issue leading to x redefined

```
cd repro/xredefined
node ../repro.js --port $PORT --path dump/ --file repro.log
```

Expected output:

```
> cache build
> Display request server/invalidate
> Display request display/completion
> Display request display/completion
> compilation
=> Error:
tests/partials/TestImperativeAst.hx:30: characters 18-46 : [2] Instance constructor not found: hxser.gen.CodeBuilder
Done.
```

### 2nd repro - Get x redefined error

```
cd repro/xredefined
node ../repro.js --port $PORT --path dump/ --file repro-1.log
```

Expected output:

```
> cache build
> Display request server/invalidate
> Display request display/completion
> Display request display/completion
> Display request display/completion
> compilation
=> Error:
Type name hxser.gen.CodeBuilder is redefined from module hxser.gen.CodeBuilder
Done.
```

### 3rd repro - Broken completion

```
cd repro/xredefined
node ../repro.js --port $PORT --path dump/ --file repro-2.log
```

Expected output:

```
> cache build
> Display request server/invalidate
> Display request display/completion
> Display request display/completion
> Display request display/completion
> Display request display/completion
=> Completion request failed
Done.
```
