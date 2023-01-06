# Copyright (c) 2020-2023 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require tcltest 2.5  ;# -errorCode option is relatively recent - make sure it's available

set thisDir [file dirname [file normalize [info script]]]
cd $thisDir
# by default, -tmpdir is the same as -testdir
tcltest::configure -testdir $thisDir -verbose pe {*}$argv
# Default is -singleproc 0, so every .test file is run in a subprocess
# PROs:
# - isolation of global variables etc
# - clear error message if Tcl crashes
# CONs:
# - Tcl debugger doesn't work
# - any output to stderr is considered as a failure, and there's no -ignorestderr for tcltest
# - need to [source] test_utils in every .test file

exit [tcltest::runAllTests]
