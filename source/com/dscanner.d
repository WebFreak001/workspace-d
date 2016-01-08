module workspaced.com.dscanner;

import std.json;
import std.conv;
import std.path;
import std.stdio;
import std.regex;
import std.string;
import std.process;
import std.algorithm;
import core.thread;

import painlessjson;

import workspaced.api;

@component("dscanner") :

@load void start(string dir, string dscannerPath = "dscanner")
{
	cwd = dir;
	execPath = dscannerPath;
}

@unload void stop()
{
}

@arguments("subcmd", "lint")
@async void lint(AsyncCallback cb, string file)
{
	new Thread({
		try
		{
			ProcessPipes pipes = raw([execPath, "-S", file, "--config", buildPath(cwd, "dscanner.ini")]);
			scope (exit)
				pipes.pid.wait();
			string[] res;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
				res ~= pipes.stdout.readln();
			DScannerIssue[] issues;
			foreach (line;
			res)
			{
				if (!line.length)
					continue;
				auto match = line[0 .. $ - 1].matchFirst(dscannerIssueRegex);
				if (!match)
					continue;
				DScannerIssue issue;
				issue.file = match[1];
				issue.line = toImpl!int(match[2]);
				issue.column = toImpl!int(match[3]);
				issue.type = match[4];
				issue.description = match[5];
				issues ~= issue;
			}
			cb(null, issues.toJSON);
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

@arguments("subcmd", "list-definitions")
@async void listDefinitions(AsyncCallback cb, string file)
{
	new Thread({
		try
		{
			ProcessPipes pipes = raw([execPath, "-c", file]);
			scope (exit)
				pipes.pid.wait();
			string[] res;
			while (pipes.stdout.isOpen && !pipes.stdout.eof)
				res ~= pipes.stdout.readln();
			DefinitionElement[] definitions;
			foreach (line;
			res)
			{
				if (!line.length || line[0] == '!')
					continue;
				line = line[0 .. $ - 1];
				string[] splits = line.split('\t');
				DefinitionElement definition;
				definition.name = splits[0];
				definition.type = splits[3];
				definition.line = toImpl!int(splits[4][5 .. $]);
				if (splits.length > 5)
					foreach (attribute;
				splits[5 .. $])
				{
					string[] sides = attribute.split(':');
					definition.attributes[sides[0]] = sides[1 .. $].join(':');
				}
				definitions ~= definition;
			}
			cb(null, definitions.toJSON);
		}
		catch (Throwable e)
		{
			cb(e, JSONValue(null));
		}
	}).start();
}

private __gshared:

string cwd, execPath;

auto raw(string[] args, Redirect redirect = Redirect.all)
{
	auto pipes = pipeProcess(args, redirect, null, Config.none, cwd);
	return pipes;
}

auto dscannerIssueRegex = ctRegex!`^(.+?)\((\d+)\:(\d+)\)\[(.*?)\]: (.*)`;
struct DScannerIssue
{
	string file;
	int line, column;
	string type;
	string description;
}

struct OutlineTreeNode
{
	string definition;
	int line;
	OutlineTreeNode[] children;
}

struct DefinitionElement
{
	string name;
	int line;
	string type;
	string[string] attributes;
}