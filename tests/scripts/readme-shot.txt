# The README's screenshot (tests/scripts/readme-shot.sh): demo data only.
wait 800
ui_command {"type":"set_theme","name":"graphite"}
ui_command {"type":"set_appearance","mode":"dark"}
resize 1400 860
# the launch DIR opened a new chat in recipe-box: close it, open r1
waitfor Import 15000
command {"type":"close_session","session":$session}
wait 300
command {"type":"open_session","project_id":$project,"pi_session_id":"r1"}
waitfor parseCsv 15000
command {"type":"markdown_open","path":"README.md"}
wait 300
command {"type":"browser_open","url":"pidesk-test://web/demo.html"}
web_title Recipe Box 15000
web_waitpaint 15000
command {"type":"new_shell_tab","session":$session}
wait 800
command {"type":"focus_tab","tab_id":$pitab}
wait 1500
shot readme/deckhand
quit
