# Copyright 2020 Petro Kazmirchuk https://github.com/Kazmirchuk
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set subjectRegex {^[[:alnum:]_-]+$}

proc check {subj} {
    if {[string length $subj] == 0} {
        return false
    }
    foreach token [split $subj .] {
        if {![regexp $::subjectRegex $token]} {
            return false
        }
    }
    return true
}

proc checkWildcard {subj} {
    if {[string length $subj] == 0} {
        return false
    }
    foreach token [split $subj .] {
        if {[regexp $::subjectRegex $token] || $token == "*" || $token == ">" } {
            continue
        }
        return false
    }
    return true
}

puts "all valid subjects:"
puts [check foo]
puts [check FOO.ba_r]
puts [check foo1.bAr2.ba-z]
puts "all invalid subjects:"
puts [check ""]
puts [check .]
puts [check foo..bar]
puts [check "foo. .bar"]
puts [check "fOo. bar"]
puts [check fo*o]
puts [check foo.]

puts "all valid wildcards:"
puts [checkWildcard foo.*]
puts [checkWildcard foo.bar]
puts [checkWildcard foo]
puts [checkWildcard foo.>]
puts [checkWildcard *.foo.*]
puts "all invalid wildcards:"
puts [checkWildcard foo*]
puts [checkWildcard foo>]
puts [checkWildcard foo.*bar]
puts [checkWildcard *foo.*]
