# Copyright (c) 2020 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require lambda
package require tcltest

# shortcut to locate the nats package; use proper Tcl mechanisms in production! e.g. TCLLIBPATH
set thisDir [file dirname [file normalize [info script]]]
lappend auto_path [file join $thisDir ..]
package require nats

source [file join $thisDir test_utils.tcl]
# by default tcltest will exit with 0 even if some tests failed
proc tcltest::cleanupTestsHook {} {
    variable numTests
    set ::exitCode [expr {$numTests(Failed) > 0}]
}
cd $thisDir
# by default, -tmpdir is the same as -testdir
tcltest::configure -testdir $thisDir -singleproc 1 {*}$argv

# due to -singleproc 1, all *.test will be sourced by the current interpreter, so we can do [namespace import] only once here
namespace import ::tcltest::test
namespace import test_utils::*

# NB! tcltest -errorCode is not available on Linux in Tcl 8.6.8, so I have to use [catch] instead
tcltest::runAllTests

exit $exitCode
