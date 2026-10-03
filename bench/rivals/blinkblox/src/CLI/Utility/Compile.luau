--!strict

---- Imports ----

local fs = require("@lune/fs")
local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Attributes = require("../../Modules/Attributes")
local Error = require("../../Modules/Error")
local Generator = require("../../Generator")
local GetDefinitionFilePath = require("./GetDefinitionFilePath")
local Parser = require("../../Parser")
local PathParser = require("../../Modules/Path")
local Report = require("./Report")
local Verify = require("./Verify")

---- Settings ----

export type CompileOptions = {
	Debug: boolean,
	Silent: boolean,
	Compact: boolean,
	YesToEverything: boolean,
	OutputAbstractSyntaxTree: boolean,
	--> What `@profile` compiles under; nil means the default. See Modules/Attributes.
	Profile: string?,
	--> Parse and generate everything, write nothing: `--check`.
	Check: boolean?,
	--> Print the diagnostics as one JSON document on standard output instead of rendering them:
	--> `--json`. See Report.luau.
	Json: boolean?,
	--> Compare every would-be output with the file on disk and write nothing: `--verify`. Implies
	--> `Check`. See Verify.luau.
	Verify: boolean?,
}

--- What one compile produced besides its diagnostics: the paths written, and under `--verify` the
--- comparison of each would-be output with the disk.
type Results = {
	Outputs: { string },
	Verified: { Verify.Entry },
}

---- Constants ----

local Utility = {}

---- Variables ----

---- Private Functions ----

local function Message(Color: stdio.Color, Options: CompileOptions, ...)
	if Options.Silent then
		return
	end

	stdio.write(stdio.color(Color))
	print(...)
	stdio.write(stdio.color("reset"))
end

local function FormatTime(Time: number): string
	if Time < 1E-6 then
		return `{Time * 1E+9} ns`
	elseif Time < 0.001 then
		return `{Time * 1E+6} us`
	elseif Time < 1 then
		return `{Time * 1000} ms`
	else
		return `{Time} seconds`
	end
end

local function CreateDirectoryIfNotFound(Path: string, Options: CompileOptions)
	local Directory = PathParser.Directory(Path) or "./"
	if fs.isDir(Directory) then
		return
	end

	--> `stdio.prompt` does not degrade when stdin is not a TTY -- it throws
	--> "IO error: not a terminal", and under some runners it simply blocks with nothing printed. So
	--> a build driven by a script, a git hook or CI used to hang or fail here for no visible reason,
	--> which is why every automated caller has to remember `--yes`.
	--> Asking is only meaningful when someone is there to answer: with no terminal, creating the
	--> directory is the answer the user already gave by naming that output path in the schema.
	local Result = Options.YesToEverything
	if not Result then
		local Asked, Answer = pcall(function(): boolean
			return stdio.prompt("confirm", `Directory {Directory} doesn't exist, create directory?`)
		end)
		Result = if Asked then Answer else true
	end

	if Result then
		fs.writeDir(Directory)
		return
	end

	error("User refused prompt to create directory")
end

--- Writes one output and records its path. A check writes and records nothing; a verify compares
--- the output with the file already at its path, and records that instead.
local function Write(Path: string, Contents: string, Options: CompileOptions, Results: Results)
	if Options.Verify then
		table.insert(Results.Verified, Verify.Compare(Path, Contents))
		return
	elseif Options.Check then
		return
	end

	fs.writeFile(Path, Contents)
	table.insert(Results.Outputs, PathParser.Normalise(Path))
end

--- The whole compile. `Results` collects every path written, for `--json` to report.
local function Build(Path: string, Options: CompileOptions, Results: Results)
	local FilePath = GetDefinitionFilePath(Path)
	Error.SetCompact(Options.Compact)

	Message("cyan", Options, `Reading source from {FilePath}...`)
	local Source = fs.readFile(FilePath)

	Message("blue", Options, "Parsing source into AST...")
	local FileDirectory = PathParser.Directory(FilePath) or "./"

	--> The path as given, normalised, rather than the bare file name: every diagnostic names this
	--> file, and a name alone cannot be opened from wherever the compiler was run.
	local SourceParser = Parser.new(FileDirectory, PathParser.Normalise(FilePath), nil, Attributes.new(Options.Profile))

	local ParseStart = os.clock()
	local AbstractSyntaxTree = SourceParser:Parse(Source)
	local ParseTime = (os.clock() - ParseStart)

	if Options.OutputAbstractSyntaxTree then
		print(AbstractSyntaxTree.Value.Options)
		print(AbstractSyntaxTree.Value.Declarations)
		return
	end

	local FileOptions = AbstractSyntaxTree.Value.Options
	local ClientOutputPath = FileOptions.ClientOutput
	local ServerOutputPath = FileOptions.ServerOutput

	--> Level 0: the line of this file that noticed is no help to someone whose schema lacks the option.
	if not ClientOutputPath then
		error("A client output path must be defined.", 0)
	end

	if not ServerOutputPath then
		error("A server output path must be defined.", 0)
	end

	local ClientTypescriptPath
	local ServerTypescriptPath

	do
		local Directory, Filename = PathParser.Components(ClientOutputPath)
		local TypescriptFilename = if Filename == "init" then "index" else Filename
		ClientOutputPath = `{Directory}/{Filename}.luau`
		ClientTypescriptPath = if PathParser.PathType(ClientOutputPath) == "absolute"
			then `{Directory}/{TypescriptFilename}.d.ts`
			else `{FileDirectory}{Directory}/{TypescriptFilename}.d.ts`
	end

	do
		local Directory, Filename = PathParser.Components(ServerOutputPath)
		local TypescriptFilename = if Filename == "init" then "index" else Filename
		ServerOutputPath = `{Directory}/{Filename}.luau`
		ServerTypescriptPath = if PathParser.PathType(ServerOutputPath) == "absolute"
			then `{Directory}/{TypescriptFilename}.d.ts`
			else `{FileDirectory}{Directory}/{TypescriptFilename}.d.ts`
	end

	local TypesOutput: string

	local ClientOutput: string
	local ServerOutput: string

	if PathParser.PathType(ClientOutputPath) == "absolute" then
		ClientOutput = ClientOutputPath
	else
		ClientOutput = `{FileDirectory}{ClientOutputPath}`
	end

	if PathParser.PathType(ServerOutputPath) == "absolute" then
		ServerOutput = ServerOutputPath
	else
		ServerOutput = `{FileDirectory}{ServerOutputPath}`
	end

	if not Options.Check then
		CreateDirectoryIfNotFound(ClientOutput, Options)
		CreateDirectoryIfNotFound(ServerOutput, Options)
	end

	Message("blue", Options, "Generating output files...")
	local FilesStart = os.clock()

	local ServerGenerateStart = os.clock()
	local ServerSource = Generator.Generate("Server", AbstractSyntaxTree)
	local ServerGenerateTime = (os.clock() - ServerGenerateStart)

	local ClientGenerateStart = os.clock()
	local ClientSource = Generator.Generate("Client", AbstractSyntaxTree)
	local ClientGenerateTime = (os.clock() - ClientGenerateStart)

	local TypesSource: string?
	if FileOptions.TypesOutput then
		--> The OUTPUT path decides whether it needs the schema's directory prepended -- not the path
		--> of the schema itself, which is what this used to test. Compiling by absolute path with a
		--> relative TypesOutput therefore wrote the types module relative to the working directory
		--> while the server and client modules landed correctly next to the schema.
		TypesOutput = if PathParser.PathType(FileOptions.TypesOutput) == "absolute"
			then FileOptions.TypesOutput
			else `{FileDirectory}{FileOptions.TypesOutput}`
		TypesSource = Generator.GenerateShared(AbstractSyntaxTree)
	end

	local ClientTypescriptSource: string?
	local ServerTypescriptSource: string?
	if FileOptions.Typescript then
		ClientTypescriptSource = Generator.GenerateTypescript("Client", AbstractSyntaxTree)
		ServerTypescriptSource = Generator.GenerateTypescript("Server", AbstractSyntaxTree)
	end

	local FilesTime = (os.clock() - FilesStart)
	Write(ServerOutput, ServerSource, Options, Results)
	Write(ClientOutput, ClientSource, Options, Results)

	if TypesSource and TypesOutput then
		if not Options.Check then
			CreateDirectoryIfNotFound(TypesOutput, Options)
		end

		Write(TypesOutput, TypesSource, Options, Results)
	end

	if ClientTypescriptSource and ServerTypescriptSource then
		Write(ClientTypescriptPath, ClientTypescriptSource, Options, Results)
		Write(ServerTypescriptPath, ServerTypescriptSource, Options, Results)
	end

	if not Options.Verify then
		Message(
			"green",
			Options,
			if Options.Check then "Schema checked, nothing written." else "Network files generated!"
		)
	end

	if Options.Debug and not Options.Silent then
		print(`[DEBUG]: Parsed source in {FormatTime(ParseTime)}.`)
		print(`[DEBUG]: Generated server luau in {FormatTime(ServerGenerateTime)}.`)
		print(`[DEBUG]: Generated client luau in {FormatTime(ClientGenerateTime)}.`)
		print(`[DEBUG]: Generated files in {FormatTime(FilesTime)}.`)
		print(`[DEBUG]: Completed everything in {FormatTime(ParseTime + FilesTime)}.`)
	end
end

---- Public Functions ----

function Utility.Compile(Path: string, Options: CompileOptions)
	--> A verify must never touch the disk, so it is a check first: no directory created, no prompt.
	if Options.Verify then
		Options = table.clone(Options)
		Options.Check = true
	end

	if not Options.Json then
		local Results: Results = { Outputs = {}, Verified = {} }
		Build(Path, Options, Results)
		if Options.Verify and not Options.OutputAbstractSyntaxTree then
			Verify.Print(Results.Verified, Options.Silent)
			if not Verify.Passed(Results.Verified) then
				process.exit(1)
			end
		end

		return
	end

	--> Standard output carries the JSON document and nothing else, so nothing else may print there:
	--> the progress lines are silenced, and every diagnostic goes to the collector instead.
	local Quiet = table.clone(Options)
	Quiet.Silent = true
	Quiet.Debug = false

	local Collector = Report.Collect()
	local Results: Results = { Outputs = {}, Verified = {} }
	local Success, Why = pcall(function(): nil
		Build(Path, Quiet, Results)
		return nil
	end)
	Error.OnEmit = nil

	--> A diagnostic error has been collected already, and what the pcall caught is the throw that
	--> aborted the compile after it. Anything else failed outside the schema and is reported as is.
	if not Success and not Collector.Failed then
		local Resolved, FilePath = pcall(GetDefinitionFilePath, Path)
		Report.Fail(Collector, PathParser.Normalise(if Resolved then FilePath else Path), tostring(Why))
	end

	--> A stale or missing file fails the run as an error would, so `success` keeps meaning exit code 0.
	if Options.Verify and Success and not Verify.Passed(Results.Verified) then
		Collector.Failed = true
	end

	print(Report.Encode(Collector, Results.Outputs, if Options.Verify then Results.Verified else nil))
	if Collector.Failed then
		process.exit(1)
	end
end

---- Initialization ----

---- Connections ----

return Utility
