## repro-completion-files: writes the shell completion files of a program
## described in its project's ``repro.nim``.
##
## The completion edge the provider gives an executable with a ``cli:``
## section runs it as
##
##   repro-completion-files --program=<name> --entry-list=<file>
##     --out-dir=<dir>
##
## It never runs the program: the scripts depend only on the program's name
## and on the completion entry word, read from the entry list its compile
## wrote. Everything it does is ``repro_project_dsl/completion_files``'s
## ``runProducer``; see that module for the files and the word.

import std/os

import repro_project_dsl/completion_files

when isMainModule:
  quit runProducer(commandLineParams())
