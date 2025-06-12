#!/usr/bin/env sh

# byggsteg-woodpecker

# Copyright © Josep Bigorra <jjbigorra@gmail.com>

# byggsteg-woodpecker is free software: you can redistribute it and/or modify
# it under the terms of the Lesser GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.

# byggsteg-woodpecker is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# Lesser GNU General Public License for more details.

# You should have received a copy of the Lesser GNU General Public License
# along with byggsteg-woodpecker.  If not, see <https://www.gnu.org/licenses/>.

. "prelude.sh"

get_token_byggsteg() {
    curl -s -i "$PLUGIN_BYGGSTEG_URL/api/v1/login" \
      -X POST \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "username=$PLUGIN_BYGGSTEG_EMAIL" \
      --data-urlencode "password=$PLUGIN_BYGGSTEG_PASSWORD" \
          | grep -i "x-bewaking-byggsteg" | cut -d' ' -f2 > x-bewaking-byggsteg
}

main() {
    log_info "Obtaining Byggsteg token..."
    log_info "POST call to $PLUGIN_BYGGSTEG_URL/api/v1/login"
    
    retry_command get_token_byggsteg

    test -s "x-bewaking-byggsteg" && exit
    log_info "Byggsteg token fetched successfully"
}

# Run the main function
main
