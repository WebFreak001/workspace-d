/// Workspace-d component that provide import paths and errors from a
/// compile_commands.json file generated by a build system.
/// See https://clang.llvm.org/docs/JSONCompilationDatabase.html
module workspaced.com.ccdb;

import std.exception;
import std.file;
import std.json;
import std.stdio;

import workspaced.api;

import containers.hashset;

import dub.internal.vibecompat.core.log;

@component("ccdb")
class ClangCompilationDatabaseComponent : ComponentWrapper
{
	mixin DefaultComponentWrapper;

	protected void load()
	{
		logDebug("loading ccdb component");

		if (config.get!bool("ccdb", "registerImportProvider", true))
			importPathProvider = &imports;
		if (config.get!bool("ccdb", "registerStringImportProvider", true))
			stringImportPathProvider = &stringImports;
		if (config.get!bool("ccdb", "registerImportFilesProvider", false))
			importFilesProvider = &fileImports;
		if (config.get!bool("ccdb", "registerProjectVersionsProvider", true))
			projectVersionsProvider = &versions;
		if (config.get!bool("ccdb", "registerDebugSpecificationsProvider", true))
			debugSpecificationsProvider = &debugVersions;

		try
		{
			if (config.get!string("ccdb", null))
			{
				const dbPath = config.get!string("ccdb", "dbPath");
				if (!dbPath)
				{
					throw new Exception("ccdb.dbPath is not provided");
				}
				loadDb(dbPath);
			}
		}
		catch (Exception e)
		{
			stderr.writeln("Clang-DB Error (ignored): ", e);
		}
	}

	private void loadDb(string filename)
	{
		import std.algorithm : each, filter, map;
		import std.array : array;

		string jsonString = cast(string) assumeUnique(read(filename));
		auto json = parseJSON(jsonString);
		// clang db can be quite large (e.g. 100 k lines of JSON data on large projects)
		// we release memory when possible to avoid having at the same time more than
		// two represention of the same data
		jsonString = null;

		HashSet!string imports;
		HashSet!string stringImports;
		HashSet!string fileImports;
		HashSet!string versions;
		HashSet!string debugVersions;

		json.array
			.map!(jv => CompileCommand.fromJson(jv))
			.filter!(cc => cc.isValid)
			.each!(cc =>
					cc.feedOptions(imports, stringImports, fileImports, versions, debugVersions)
			);

		_importPaths = imports[].array;
		_stringImportPaths = stringImports[].array;
		_importFiles = fileImports[].array;
		_versions = versions[].array;
		_debugVersions = debugVersions[].array;
	}

	/// Lists all import paths
	string[] imports() @property nothrow
	{
		return _importPaths;
	}

	/// Lists all string import paths
	string[] stringImports() @property nothrow
	{
		return _stringImportPaths;
	}

	/// Lists all import paths to files
	string[] fileImports() @property nothrow
	{
		return _importFiles;
	}

	/// Lists the currently defined versions
	string[] versions() @property nothrow
	{
		return _versions;
	}

	/// Lists the currently defined debug versions (debug specifications)
	string[] debugVersions() @property nothrow
	{
		return _debugVersions;
	}

private:

	string[] _importPaths, _stringImportPaths, _importFiles, _versions, _debugVersions;
}

private struct CompileCommand
{
	string directory;
	string file;
	string[] args;
	string output;

	static CompileCommand fromJson(JSONValue json)
	{
		import std.algorithm : map;
		import std.array : array;

		CompileCommand cc;

		cc.directory = json["directory"].str;
		cc.file = json["file"].str;

		if (auto args = "arguments" in json)
		{
			cc.args = args.array.map!(jv => jv.str).array;
		}
		else if (auto cmd = "command" in json)
		{
			cc.args = unescapeCommand(cmd.str);
		}
		else
		{
			throw new Exception(
				"Either 'arguments' or 'command' missing from Clang compilation database");
		}

		if (auto o = "output" in json)
		{
			cc.output = o.str;
		}

		return cc;
	}

	@property bool isValid() const
	{
		import std.algorithm : endsWith;

		if (args.length <= 1)
			return false;
		if (!file.endsWith(".d"))
			return false;
		return true;
	}

	void feedOptions(
		ref HashSet!string imports,
		ref HashSet!string stringImports,
		ref HashSet!string fileImports,
		ref HashSet!string versions,
		ref HashSet!string debugVersions)
	{
		import std.algorithm : startsWith;

		enum importMark = "-I"; // optional =
		enum stringImportMark = "-J"; // optional =
		enum fileImportMark = "-i=";
		enum versionMark = "-version=";
		enum debugMark = "-debug=";

		foreach (arg; args)
		{
			const mark = arg.startsWith(
				importMark, stringImportMark, fileImportMark, versionMark, debugMark
			);

			switch (mark)
			{
			case 0:
				break;
			case 1:
			case 2:
				if (arg.length == 2)
					break; // ill-formed flag, we don't need to care here
				const st = arg[2] == '=' ? 3 : 2;
				const path = getPath(arg[st .. $]);
				if (mark == 1)
					imports.put(path);
				else
					stringImports.put(path);
				break;
			case 3:
				fileImports.put(getPath(arg[fileImportMark.length .. $]));
				break;
			case 4:
				versions.put(getPath(arg[versionMark.length .. $]));
				break;
			case 5:
				debugVersions.put(getPath(arg[debugMark.length .. $]));
				break;
			default:
				break;
			}
		}
	}

	string getPath(string filename)
	{
		import std.path : absolutePath;

		return absolutePath(filename, directory);
	}
}

private string[] unescapeCommand(string cmd)
{
	string[] result;
	string current;

	bool inquot;
	bool escapeNext;

	foreach (dchar c; cmd)
	{
		if (escapeNext)
		{
			escapeNext = false;
			if (c != '"')
			{
				current ~= '\\';
			}
			current ~= c;
			continue;
		}

		switch (c)
		{
		case '\\':
			escapeNext = true;
			break;
		case '"':
			inquot = !inquot;
			break;
		case ' ':
			if (inquot)
			{
				current ~= ' ';
			}
			else
			{
				result ~= current;
				current = null;
			}
			break;
		default:
			current ~= c;
			break;
		}
	}

	if (current.length)
	{
		result ~= current;
	}
	return result;
}

@("unescapeCommand")
unittest
{
	const cmd = `"ldc2" "-I=..\foo\src" -I="..\with \" and space" "-m64" ` ~
		`-of=foo/libfoo.a.p/src_foo_bar.d.obj -c ../foo/src/foo/bar.d`;

	const cmdArgs = unescapeCommand(cmd);

	const args = [
		"ldc2", "-I=..\\foo\\src", "-I=..\\with \" and space", "-m64",
		"-of=foo/libfoo.a.p/src_foo_bar.d.obj", "-c", "../foo/src/foo/bar.d",
	];

	assert(cmdArgs == args);
}
