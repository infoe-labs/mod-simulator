extends Node

## Autoload: parses the two JSON files exactly once at boot. Nothing in the
## game touches FileAccess or JSON.parse_string during gameplay.

var balance: Balance
var catalog: MessageCatalog
var ready_flag := false


func _ready() -> void:
	balance = Balance.load_default()
	catalog = MessageCatalog.load_default()
	catalog.balance = balance
	ready_flag = catalog.is_loaded()
	if not ready_flag:
		push_error("Content failed to load — the game cannot start.")
	else:
		print("ContentDB: %d messages, %d users, %d phases" % [
			catalog.count(), catalog.users.size(), balance.phases().size()])


func is_ready() -> bool:
	return ready_flag


func bal() -> Balance:
	if balance == null:
		balance = Balance.load_default()
	return balance


func cat() -> MessageCatalog:
	if catalog == null:
		catalog = MessageCatalog.load_default()
	return catalog


func new_sim(mode: String, seed_value: int) -> Sim:
	var s := Sim.new(bal(), cat())
	s.configure(mode, seed_value)
	return s


func mode_label(mode: String) -> String:
	return String(bal().mode_config(mode).get("label", mode))
