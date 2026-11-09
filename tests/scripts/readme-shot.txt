# The README's clip and screenshot (tests/scripts/readme-shot.sh): demo data only.
# Each `shot readme/frames/NN-MS` is a frame of the clip, shown for MS milliseconds;
# `shot readme/deckhand` is the screenshot.
wait 800
ui_command {"type":"set_theme","name":"graphite"}
ui_command {"type":"set_appearance","mode":"dark"}
resize 1400 860
# the launch DIR opened a new chat in recipe-box: close it; open two other projects' sessions
# (garden-planner working, notes waiting for you), then r1, played live (demo-pi.py live())
waitfor Import 15000
command {"type":"close_session","session":$session}
wait 300
command {"type":"add_project","cwd":"$homedir/garden-planner"}
command {"type":"open_session","project_id":$last,"pi_session_id":"g1"}
waitfor garden-planner (main) 15000
command {"type":"add_project","cwd":"$homedir/notes"}
command {"type":"open_session","project_id":$last,"pi_session_id":"n1"}
waitfor notes (main) 15000
command {"type":"add_project","cwd":"$homedir/code/recipe-box"}
command {"type":"open_session","project_id":$last,"pi_session_id":"r1"}
waitfor $0.000 15000
wait 500
shot readme/frames/00-1300
# the prompt, typed
type Import recipes from a CSV
shot readme/frames/01-120
type  export. The file in
shot readme/frames/02-120
type  fixtures/recipes.csv has a
shot readme/frames/03-120
type  header row; ingredients are
shot readme/frames/04-120
type  separated by semicolons.
shot readme/frames/05-700
key enter
waitfor look at the existing 10000
shot readme/frames/06-900
waitfor 48 lines 10000
shot readme/frames/07-900
waitfor toRecipe 10000
shot readme/frames/08-1000
waitfor 3 passed 10000
shot readme/frames/09-1000
waitfor Next I can wire 10000
wait 300
shot readme/frames/10-2000
# a Markdown tab, then dragged to the right edge: a split
ui_command {"type":"set_layout","right_open":false}
command {"type":"markdown_open","path":"README.md"}
eventually 10000
assert_md Importing
shot readme/frames/11-1200
dragtab 1 by 220 160 hold
shot readme/frames/12-150
key escape
dragtab 1 by 420 300 hold
shot readme/frames/13-150
key escape
dragtab 1 right 0 hold
shot readme/frames/14-1000
key escape
dragtab 1 right 0
wait 600
shot readme/frames/15-1600
# a browser tab on the app beside the agent, in the right pane
command {"type":"browser_open","url":"deckhand-test://web/demo.html"}
web_title Recipe Box 15000
web_waitpaint 15000
wait 500
shot readme/frames/16-2800
ui_command {"type":"set_layout","right_open":true}
wait 800
shot readme/deckhand
quit
