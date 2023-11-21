# Copyright (c) 2020-2023 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require tcltest 2.5  ;# -errorCode option is relatively recent - make sure it's available

set thisDir [file dirname [file normalize [info script]]]
# doing a simple [cd] and -testdir is enough for the tests to work
# but [workingDirectory] and -tmpdir are needed for an accurate output header
tcltest::workingDirectory $thisDir
tcltest::configure -testdir $thisDir -tmpdir [file join $thisDir temp] -verbose pe {*}$argv
# Default is -singleproc 0, so every .test file is run in a subprocess
# PROs:
# - isolation of global variables etc
# - clear error message if Tcl crashes
# CONs:
# - Tcl debugger doesn't work
# - any output to stderr is considered as a failure, and there's no -ignorestderr for tcltest
# - need to [source] test_utils in every .test file
# - some Tcl errors become hidden, while they are visible with -singleproc 1
if {![tcltest::singleProcess]} {
    encoding system utf-8  ;# in test key_value-utf8 printing Unicode to the console produces corrupted output unless I call this
}
exit [tcltest::runAllTests]
