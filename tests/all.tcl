# Copyright (c) 2020-2022 Petro Kazmirchuk https://github.com/Kazmirchuk

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

package require nats  ;# if not found, add it to TCLLIBPATH
package require lambda
package require tcltest 2.5  ;# -errorCode option is relatively recent - make sure it's available

set thisDir [file dirname [file normalize [info script]]]
source [file join $thisDir test_utils.tcl]

cd $thisDir
# by default, -tmpdir is the same as -testdir
# to get messages about passed tests: -verbose bpe 
tcltest::configure -testdir $thisDir -singleproc 1 {*}$argv

# due to -singleproc 1, all *.test will be sourced by the current interpreter, so we can do [namespace import] only once here
namespace import ::tcltest::test
namespace import test_utils::*

exit [tcltest::runAllTests]
