package require fileutil

set version [lindex $argv 0]

set module \
{# Copyright (c) 2020-2024 Petro Kazmirchuk https://github.com/Kazmirchuk
# Copyright (c) 2023 ANT Solutions https://antsolutions.eu/

# Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in compliance with the License. You may obtain a copy of the License at http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software distributed under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the License for the specific language governing permissions and  limitations under the License.

}
foreach f {nats_client.tcl server_pool.tcl jet_stream.tcl key_value.tcl} {
    set inLicense 1
    fileutil::foreachLine line $f {
        if {[string index $line 0] in {# ""} && $inLicense} {
            continue
        }
        set inLicense 0
        append module $line "\n"
    }
}
append module "package provide nats $version\n"

fileutil::writeFile -encoding utf-8 -translation lf nats-$version.tm $module
