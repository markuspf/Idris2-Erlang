module Compiler.Erlang.Cmd

import Data.String


%default total


escapeCmd : List String -> String
escapeCmd components = unwords (map escapeComponent components)
  where
    escapeChar : Char -> String
    escapeChar '\'' = "'\"'\"'"
    escapeChar c    = cast c
    escapeComponent : String -> String
    escapeComponent component = "'" ++ concat (map escapeChar (unpack component)) ++ "'"

evalErlangSourceCmd : (erl : String) -> (code : String) -> String
evalErlangSourceCmd erl code =
  escapeCmd [erl, "-noshell", "-boot", "no_dot_erlang", "-eval", code]

pmapErlangCode : String
pmapErlangCode =
  """
  Collect = fun
    Collect([]) -> [];
    Collect([{Pid, MRef} | Next]) ->
      receive
        {Pid, Res} ->
          erlang:demonitor(MRef, [flush]),
          [{ok, Res} | Collect(Next)];
        {'DOWN', MRef, process, Pid, Reason} ->
          [{error, Reason} | Collect(Next)]
      end
  end,
  Pmap = fun(F, Es) ->
    Parent = self(),
    Running = [spawn_monitor(fun() -> Parent ! {self(), F(E)} end) || E <- Es],
    Collect(Running)
  end
  """


export
compileErlToBeamCmd : (erlc : String) -> (srcFiles : List String) -> (outputDir : String) -> String
compileErlToBeamCmd erlc srcFiles outputDir =
  escapeCmd $ [erlc, "-W0", "-o", outputDir] ++ srcFiles

erlShowPath : String -> String
erlShowPath = show -- The Show implementation is close enough to Erlang syntax

erlShowPaths : List String -> String
erlShowPaths = show -- The Show implementation is close enough to Erlang syntax

-- Tips to make the generated Escript relocatable:
-- 1. Output the Escript to the current directory or to an absolute path.
-- 2. Specify the main module using the `emu_args` option.
-- 3. Archive `.beam` files instead of `.erl` files.
export
archiveErlToEscriptCmd : (erl : String) -> (inputDir : String) -> (inputFilenames : List String) -> (outputDir : String) -> (mainModule : String) -> String
archiveErlToEscriptCmd erl inputDir inputFilenames outputDir mainModule =
  let code =
        """
        InputDir = \{erlShowPath inputDir},
        InputFilenames = \{erlShowPaths inputFilenames},
        OutputDir = \{erlShowPath outputDir},
        MainModule = \{erlShowPath mainModule},
        GeneratedEscriptFile = filename:join(InputDir, MainModule),
        OutputEscriptFile = filename:join(OutputDir, MainModule),
        EmuArgs = "-escript main " ++ MainModule,
        CompileBeam = fun(Filename) ->
          {ok, ModuleName} = compile:noenv_file(Filename, []),
          OutputFilename = atom_to_list(ModuleName) ++ ".beam",
          OutputFilename
        end,
        {ok, CurrentDir} = file:get_cwd(),
        file:set_cwd(InputDir),
        \{pmapErlangCode},
        CompileResult = Pmap(CompileBeam, InputFilenames),
        BeamFilenames = lists:map(fun ({ok, Filename}) -> Filename end, CompileResult),
        escript:create(MainModule, [shebang, {emu_args, EmuArgs}, {archive, BeamFilenames, []}]),
        file:change_mode(MainModule, 8#00755),
        file:set_cwd(CurrentDir),
        file:rename(GeneratedEscriptFile, OutputEscriptFile),
        halt(0)
        """
  in evalErlangSourceCmd erl code

export
compileAbstrToBeamCmd : (erl : String) -> (srcFiles : List String) -> (outputDir : String) -> String
compileAbstrToBeamCmd erl srcFiles outputDir =
  let code =
        """
        SrcFiles = \{erlShowPaths srcFiles},
        OutputDir = \{erlShowPath outputDir},
        CompileAbstr = fun(File) ->
          {ok, Forms} = file:consult(File),
          {ok, ModuleName, BinaryOrCode} = compile:noenv_forms(Forms, []),
          OutputFile = filename:join(OutputDir, atom_to_list(ModuleName) ++ ".beam"),
          file:write_file(OutputFile, BinaryOrCode)
        end,
        \{pmapErlangCode},
        Pmap(CompileAbstr, SrcFiles),
        halt(0)
        """
  in evalErlangSourceCmd erl code

export
compileAbstrToErlCmd : (isMinified : Bool) -> (erl : String) -> (srcFiles : List String) -> (outputDir : String) -> String
compileAbstrToErlCmd isMinified erl srcFiles outputDir =
  let columnWidth : Int =
        if isMinified
          then 10000
          else 120
      code =
        """
        ModuleNameFromForms = fun(Forms) ->
          lists:foldl(
            fun
              ({attribute, _, module, ModuleName}, _Acc) -> {ok, ModuleName};
              (_, Acc) -> Acc
            end, not_found, Forms)
        end,
        SrcFiles = \{erlShowPaths srcFiles},
        OutputDir = \{erlShowPath outputDir},
        PrettyOpts = [{paper, \{show columnWidth}}, {ribbon, \{show columnWidth}}],
        GenerateErl = fun(File) ->
          {ok, Forms} = file:consult(File),
          {ok, ModuleName} = ModuleNameFromForms(Forms),
          OutputFile = filename:join(OutputDir, atom_to_list(ModuleName) ++ ".erl"),
          ErlangSource = erl_prettypr:format(erl_syntax:form_list(Forms), PrettyOpts),
          file:write_file(OutputFile, ErlangSource)
        end,
        \{pmapErlangCode},
        Pmap(GenerateErl, SrcFiles),
        halt(0)
        """
  in evalErlangSourceCmd erl code
