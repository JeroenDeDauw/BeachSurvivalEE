local ScenarioUtils = import('/lua/sim/ScenarioUtilities.lua')
ScenarioUtils.CreateResources = function() end

local function localImport(fileName)
	return import('/maps/beach_survival_ee.v0008/src/' .. fileName)
end

local function entropyLibImport(fileName)
	return import('/maps/beach_survival_ee.v0008/vendor/EntropyLib/src/' .. fileName)
end


local Survival_TickInterval = 0.50; -- how much delay between each script iteration

local Survival_NextSpawnTime = 0;
local Survival_CurrentTime = 0;

local Survival_GameState = 0; -- 0 pre-spawn, 1 post-spawn, 2 player win, 3 player defeat
local Survival_PlayerCount = 0; -- how many human players there are

local Survival_MarkerRefs = {{}, {}, {}, {}, {}, {}, {}, {}, {}, {}}; -- 1 center / 2 waypoint / 3 spawn / 4 aty / 5 nuke / 6 navy

local Survival_UnitCountPerMinute = 0; -- how many units to spawn per minute (taking into consideration player count)
local Survival_UnitCountPerWave = 0; -- how many units to spawn with each wave (taking into consideration player count)

local Survival_MinWarnTime = 0;

local Survival_DefUnit = nil;
local Survival_DefCheckHP = 0.0;
local Survival_DefLastHP = 0;

local Survival_AtyUnits = {};
local Survival_NukeUnits = {};

local Survival_NextNukeTime = 10000; --2040;
local Survival_NukeFrequency = 135;

local Survival_ObjectiveTime = 3600; --2160 --2160;

local entropyLib = entropyLibImport('EntropyLib.lua').newInstance('/maps/beach_survival_ee.v0008/vendor/EntropyLib/')

local Survival_WaveTables = localImport('WaveTables.lua').getWaveTables()

local unitCreator = entropyLib.newUnitCreator()
local textPrinter = entropyLib.newTextPrinter()
local notifier = entropyLib.newNotifier()
local formatter = entropyLibImport('Formatter.lua')

local function defaultOptions()
	if (ScenarioInfo.Options.opt_Survival_BuildTime == nil) then
		ScenarioInfo.Options.opt_Survival_BuildTime = 0
	end

	if (ScenarioInfo.Options.opt_Survival_EnemiesPerMinute == nil) then
		ScenarioInfo.Options.opt_Survival_EnemiesPerMinute = 32
	end

	if (ScenarioInfo.Options.opt_Survival_WaveFrequency == nil) then
		ScenarioInfo.Options.opt_Survival_WaveFrequency = 240
	end

	if (ScenarioInfo.Options.opt_BeachHealthMultiplier == nil) then
		ScenarioInfo.Options.opt_BeachHealthMultiplier = 1
	end

    if (ScenarioInfo.Options.opt_BeachDamageMultiplier == nil) then
        ScenarioInfo.Options.opt_BeachDamageMultiplier = 1
    end

	if (ScenarioInfo.Options.opt_BeachAutoReclaim == nil) then
		ScenarioInfo.Options.opt_BeachAutoReclaim = 0
	end

	if (ScenarioInfo.Options.opt_BeachAllFactions == nil) then
		ScenarioInfo.Options.opt_BeachAllFactions = 0
	end

	if (ScenarioInfo.Options.opt_BeachParagon == nil) then
		ScenarioInfo.Options.opt_BeachParagon = 0
	end
end

local function setupAutoReclaim()
	local percentage = ScenarioInfo.Options.opt_CenterAutoReclaim

	if percentage > 0 then
		unitCreator.onUnitCreated(function(unit, unitInfo)
			if unitInfo.isSurvivalSpawned then
				unit.CreateWreckage = function() end
			end
		end)

		ForkThread(
			entropyLibImport('AutoReclaim.lua').AutoResourceThread,
			percentage / 100,
			percentage / 100
		)
	end
end

local function setupHealthMultiplier()
	local multiplier = ScenarioInfo.Options.opt_BeachHealthMultiplier

	if multiplier ~= 1 then
		unitCreator.onUnitCreated(function(unit, unitInfo)
			if unitInfo.isSurvivalSpawned then
				unit:SetVeterancy(5)
				unit:SetMaxHealth(unit:GetMaxHealth() * multiplier)
				unit:SetHealth(unit, unit:GetMaxHealth())
			end
		end)
	end
end

local function setupDamageMultiplier()
	local buffUnitDamage = entropyLibImport('UnitBuff.lua').buffDamage

	unitCreator.onUnitCreated(function(unit, unitInfo)
		if unitInfo.isSurvivalSpawned then
			buffUnitDamage(unit, ScenarioInfo.Options.opt_BeachDamageMultiplier)
		end
	end)
end

local function vanguardify()
	unitCreator.onUnitCreated(function(unit, unitInfo)
		if unitInfo.isSurvivalSpawned and unitInfo.blueprintName == "DEL0204" then
			unit:SetCustomName("Minion of Vanguard")
		end
	end)
end

local function isPlayerArmy(armyName)
	return armyName == "ARMY_1" or armyName == "ARMY_2" or armyName == "ARMY_3" or armyName == "ARMY_4"
			or armyName == "ARMY_5" or armyName == "ARMY_6" or armyName == "ARMY_7" or armyName == "ARMY_8"
end

local function getPlayerArmies()
	local armies = {}

	for armyIndex, armyName in ListArmies() do
		if isPlayerArmy(armyName) then
			armies[armyIndex] = armyName
		end
	end

	return armies
end

local function setupAllFactions()
	if ScenarioInfo.Options.opt_BeachAllFactions ~= 0 then
		local allFactions = entropyLibImport('AllFactions.lua')

		for armyIndex, armyName in ListArmies() do
			if isPlayerArmy(armyName) then
				if ScenarioInfo.Options.opt_BeachAllFactions == 1 then
					allFactions.spawnExtraEngineers(ArmyBrains[armyIndex])
				else
					allFactions.spawnExtraAcus(ArmyBrains[armyIndex])
				end
			end
		end
	end
end

local welcomeMessages = localImport('WelcomeMessages.lua').newInstance(
		textPrinter,
		formatter,
		ScenarioInfo.Options,
		ScenarioInfo.map_version
)

local function showWelcomeMessages()
	welcomeMessages.startDisplay()
end

local function setBotColor()
    SetArmyColor("ARMY_SURVIVAL_ENEMY", 110, 90, 90)
end

local function setupResourceDeposits()
	entropyLib.spawnAdaptiveResources(
		localImport('../beach_survival_ee_tables.lua')
	)
end

function OnPopulate()
	ScenarioUtils.InitializeArmies()
	defaultOptions()

	setupResourceDeposits()
	setBotColor()
	setupAutoReclaim()
	setupHealthMultiplier()
	setupDamageMultiplier()
	setupAllFactions()

	Survival_InitGame()

	import('/lua/weather.lua').CreateWeather()

	showWelcomeMessages()
	vanguardify()
end


local function createSurvivalUnit(blueprint, x, z, y)
	local unit = unitCreator.create({
		isSurvivalSpawned = true,
		blueprintName = blueprint,
		armyName = "ARMY_SURVIVAL_ENEMY",
		x = x,
		z = z,
		y = y
	})

	return unit
end



-- called at start of game
--------------------------------------------------------------------------
function OnStart(self)

	LOG("----- Survival MOD: Initializing game start sequence...");

	-- start the survival tick
	ForkThread(Survival_Tick);

end



-- initializes the game settings
--------------------------------------------------------------------------
Survival_InitGame = function()

	LOG("----- Survival MOD: Configuring match settings...");

	Survival_NextSpawnTime = ScenarioInfo.Options.opt_Survival_BuildTime; -- set first wave time to build time
	Survival_MinWarnTime = Survival_NextSpawnTime - 60; -- set time for minute warning

	ScenarioInfo.Options.Victory = 'sandbox'; -- force sandbox in order to implement our own rules

	local Armies = ListArmies();
	Survival_PlayerCount = table.getn(Armies) - 2; -- save player count, subtracting the 2 AI "players"

	local ScenarioFramework = import('/lua/ScenarioFramework.lua')

	-- loop through armies
	for i, Army in ListArmies() do
		-- check if it's a human army
		if (Army == "ARMY_1" or Army == "ARMY_2" or Army == "ARMY_3" or Army == "ARMY_4" or Army == "ARMY_5" or Army == "ARMY_6" or Army == "ARMY_7" or Army == "ARMY_8") then

			SetArmyUnitCap(Army, 5000)

			ScenarioFramework.AddRestriction(Army, categories.WALL)
			ScenarioFramework.AddRestriction(Army, categories.AIR - categories.ENGINEER)

			if ScenarioInfo.Options.opt_BeachParagon == 0 then
				ScenarioFramework.AddRestriction(Army, categories.xab1401)
			end

			-- loop through other armies to ally with other human armies
			for x, ArmyX in ListArmies() do
				-- if human army
				if (ArmyX == "ARMY_1" or ArmyX == "ARMY_2" or ArmyX == "ARMY_3" or ArmyX == "ARMY_4" or ArmyX == "ARMY_5" or ArmyX == "ARMY_6" or ArmyX == "ARMY_7" or ArmyX == "ARMY_8") then 
					SetAlliance(Army, ArmyX, 'Ally'); 
				end
			end			

			SetAlliance(Army, "ARMY_SURVIVAL_ALLY", 'Ally'); -- friendly AI team
			SetAlliance(Army, "ARMY_SURVIVAL_ENEMY", 'Enemy');  -- enemy AI team

			SetAlliedVictory(Army, true); -- can win together of course :)
		end
	end

	SetAlliance("ARMY_SURVIVAL_ALLY", "ARMY_SURVIVAL_ENEMY", 'Enemy'); -- the friendly and enemy AI teams should be enemies

	SetIgnoreArmyUnitCap('ARMY_SURVIVAL_ENEMY', true); -- remove unit cap from enemy AI team

	Survival_InitMarkers(); -- find and reference all the map markers related to survival
	Survival_SpawnDef();

	Survival_CalcWaveCounts(); -- calculate how many units per wave
	Survival_CalcNukeFrequency(); -- calculate how frequently to launch nukes at the players (once launchers are spawned)

--	Survival_ObjectiveTime = Survival_ObjectiveTime * 60;

end



-- spawns a specified unit
--------------------------------------------------------------------------
Survival_InitMarkers = function()

	LOG("----- Survival MOD: Initializing marker lists...");

	local MarkerRef = nil;
	local Break = 0;
	local i = 1;

	while (Break < 6) do

		Break = 0; -- reset break counter

		-- center
		MarkerRef = GetMarker("SURVIVAL_CENTER_" .. i);

		if (MarkerRef ~= nil) then
			table.insert(Survival_MarkerRefs[1], i, MarkerRef);
--			Survival_MarkerCounts[1] = Survival_MarkerCounts[1] + 1;
		else
			Break = Break + 1;
		end

		-- path
		MarkerRef = GetMarker("SURVIVAL_PATH_" .. i);

		if (MarkerRef ~= nil) then
			table.insert(Survival_MarkerRefs[2], i, MarkerRef);
--			Survival_MarkerCounts[2] = Survival_MarkerCounts[2] + 1;
		else
			Break = Break + 1;
		end

		-- spawn
		MarkerRef = GetMarker("SURVIVAL_SPAWN_" .. i);

		if (MarkerRef ~= nil) then
			table.insert(Survival_MarkerRefs[3], i, MarkerRef);
--			Survival_MarkerCounts[3] = Survival_MarkerCounts[3] + 1;
		else
			Break = Break + 1;
		end

		-- aty
		MarkerRef = GetMarker("SURVIVAL_ATY_" .. i);

		if (MarkerRef ~= nil) then
			table.insert(Survival_MarkerRefs[4], i, MarkerRef);
--			Survival_MarkerCounts[4] = Survival_MarkerCounts[4] + 1;
		else
			Break = Break + 1;
		end

		-- nuke
		MarkerRef = GetMarker("SURVIVAL_NUKE_" .. i);

		if (MarkerRef ~= nil) then
			table.insert(Survival_MarkerRefs[5], i, MarkerRef);
--			Survival_MarkerCounts[5] = Survival_MarkerCounts[5] + 1;
		else
			Break = Break + 1;
		end

		-- navy
		MarkerRef = GetMarker("SURVIVAL_SPAWN_NAVY_" .. i);

		if (MarkerRef ~= nil) then
			table.insert(Survival_MarkerRefs[6], i, MarkerRef);
		else
			Break = Break + 1;
		end
		
		i = i + 1

	end

end



Survival_SpawnDef = function()

	LOG("----- Survival MOD: Initializing defense object...");

	local POS = ScenarioUtils.MarkerToPosition("SURVIVAL_CENTER_1");
	Survival_DefUnit = CreateUnitHPR('XRB3301', "ARMY_SURVIVAL_ALLY", POS[1], POS[2], POS[3], 0,0,0);

	Survival_DefUnit:SetReclaimable(false);
	Survival_DefUnit:SetCapturable(false);
	Survival_DefUnit:SetProductionPerSecondEnergy((Survival_PlayerCount * 100) + 0);
	Survival_DefUnit:SetConsumptionPerSecondEnergy(1);

	Survival_DefUnit:SetMaxHealth(58000 - (Survival_PlayerCount * 1000));
	Survival_DefUnit:SetHealth(nil, 58000 - (Survival_PlayerCount * 1000));
	Survival_DefUnit:SetRegenRate(100 - (Survival_PlayerCount * 5));

	local Survival_DefUnitBP = Survival_DefUnit:GetBlueprint();
	Survival_DefUnitBP.Intel.MaxVisionRadius = 400;
	Survival_DefUnitBP.Intel.MinVisionRadius = 400;
	Survival_DefUnitBP.Intel.VisionRadius = 400;

	Survival_DefUnit:SetIntelRadius('Vision', 400);

       	local ShieldSpecs = {
            ImpactEffects = 'SeraphimShieldHit01',
            ImpactMesh = '/effects/entities/ShieldSection01/ShieldSection01_mesh',
            Mesh = '/effects/entities/SeraphimShield01/SeraphimShield01_mesh',
            MeshZ = '/effects/entities/Shield01/Shield01z_mesh',
            RegenAssistMult = 60,
            ShieldEnergyDrainRechargeTime = 60,
            ShieldMaxHealth = 55000 + (Survival_PlayerCount * 5000),
            ShieldRechargeTime = 60,
            ShieldRegenRate = 290 - (Survival_PlayerCount * 10),
            ShieldRegenStartTime = 1,
            ShieldSize = 90,
            ShieldVerticalOffset = -10,
        };


	Survival_DefUnit.OldOnKilled = Survival_DefUnit.OnKilled;

	Survival_DefUnit.OnKilled = function(self, instigator, type, overkillRatio)

		notifier.failure("The defense object has been destroyed. You have lost!", 8);
		self.OldOnKilled(self, instigator, type, overkillRatio);

		Survival_GameState = 3;

		for i, army in ListArmies() do

			if (army == "ARMY_1" or army == "ARMY_2" or army == "ARMY_3" or army == "ARMY_4" or army == "ARMY_5" or army == "ARMY_6" or army == "ARMY_7" or army == "ARMY_8") then
				--killAllCommanders(army);
				GetArmyBrain(army):OnDefeat();
			end
		end
	end

	Survival_DefLastHP = Survival_DefUnit:GetHealth();

end





-- loops every TickInterval to progress main game logic
--------------------------------------------------------------------------
Survival_Tick = function(self)

	while (Survival_GameState < 2) do

		Survival_CurrentTime = GetGameTimeSeconds();

		Survival_UpdateWaves(Survival_CurrentTime);

		if (Survival_CurrentTime >= Survival_ObjectiveTime) then

			Survival_GameState = 2;
			notifier.positive("You survived the onslaught! You are victorious!", 4);
			Survival_DefUnit:SetCustomName("CHUCK NORRIS MODE!"); -- update defense object name

			for i, army in ListArmies() do
				if (army == "ARMY_1" or army == "ARMY_2" or army == "ARMY_3" or army == "ARMY_4" or army == "ARMY_5" or army == "ARMY_6" or army == "ARMY_7" or army == "ARMY_8") then
					GetArmyBrain(army):OnVictory();
				end
			end

			GetArmyBrain("ARMY_SURVIVAL_ENEMY"):OnDefeat();
		else

			if (Survival_GameState == 0) then -- build stage

				if (Survival_CurrentTime >= Survival_NextSpawnTime) then -- if build period is over
					Sync.ObjectiveTimer = 0; -- clear objective timer
					Survival_GameState = 1; -- update game state to combat mode
					notifier.warning("Space Vikings are attacking!", 4.5);
					Survival_SpawnWave(Survival_NextSpawnTime);
					Survival_NextSpawnTime = Survival_NextSpawnTime + ScenarioInfo.Options.opt_Survival_WaveFrequency; -- update next wave spawn time by wave frequency

				else -- build period still active
					Sync.ObjectiveTimer = math.floor(Survival_NextSpawnTime - Survival_CurrentTime); -- update objective timer
					Survival_DefUnit:SetCustomName(SecondsToTime(Sync.ObjectiveTimer)); -- update defense object name

					if ((Survival_MinWarnTime > 0) and (Survival_CurrentTime >= Survival_MinWarnTime)) then -- display 2 minute warning if we're at 2 minutes and it's appropriate to do so
						notifier.warning("1 minute warning!", 2);
						Survival_MinWarnTime = 0; -- reset 2 minute warning time so it wont be displayed again
					end

				end

			elseif (Survival_GameState == 1) then -- combat stage

				Sync.ObjectiveTimer = math.floor(Survival_ObjectiveTime - Survival_CurrentTime); -- update objective timer

				if (Survival_CurrentTime >= Survival_NextSpawnTime) then -- ready to spawn a wave
					Survival_SpawnWave(Survival_NextSpawnTime);
					Survival_NextSpawnTime = Survival_NextSpawnTime + ScenarioInfo.Options.opt_Survival_WaveFrequency; -- update next wave spawn time by wave frequency
				end

				Survival_DefUnit:SetCustomName('Wave Set ' ..  (Survival_WaveTables[2][1] - 1) .. "/" .. (table.getn(Survival_WaveTables[2]) - 1) ); -- .. ' (' .. SecondsToTime(Survival_CurrentTime - (Survival_WaveTables[1][Survival_WaveTables[1][1] + 1][1] * 60)).. ')');
				--SecondsToTime((Survival_WaveTables[1][(Survival_WaveTables[1][1])][1] * 60) - Survival_CurrentTime)
			end

			Survival_DefCheckHP = Survival_DefCheckHP - Survival_TickInterval;

			if (Survival_DefCheckHP <= 0) then
				if (Survival_DefUnit:GetHealth() < Survival_DefLastHP) then
					--BroadcastMSG("The Acen Accelerator is taking damage! (" .. Survival_DefUnit:GetHealth() / Survival_DefUnit:GetMaxHealth() .. "%)", 0.5);
					notifier.warning("The defense object is taking damage! (" .. math.floor(Survival_DefUnit:GetHealthPercent() * 10) .. "%)", 0.5);

					Survival_DefCheckHP = 2;
				end
			end

			Survival_DefLastHP = Survival_DefUnit:GetHealth();

			-- nuke stuff
			if (Survival_CurrentTime >= Survival_NextNukeTime) then
				Survival_FireNuke();
			end

			WaitSeconds(Survival_TickInterval);
		end
	end

	KillThread(self);

end



-- updates spawn waves
--------------------------------------------------------------------------
Survival_UpdateWaves = function(GameTime)

	local OldWaveID = 1;

	-- check the wave table times vs the wave spawn time to see which waves we spawn
	for x = 1, table.getn(Survival_WaveTables) do -- loop through each of the wavetable entries (ground/air/sea...)

--		OldWaveID = 1;
		OldWaveID = Survival_WaveTables[x][1];

		for y = Survival_WaveTables[x][1], table.getn(Survival_WaveTables[x]) do -- loop through each wave table within the category

			if (GameTime >= (Survival_WaveTables[x][y][1] * 60)) then -- compare spawn time against the first entry spawn time for each wave table
				if (Survival_WaveTables[x][1] < y) then -- should only update a wave once
				
					Survival_WaveTables[x][1] = y; -- update the wave id for this wave category

					if (x == 1) then -- if this is the special category update, immediately call the setup function
						Survival_SpawnSpecialWave(GameTime);
					end
				end
			else break; end

		end

		if (Survival_WaveTables[x][1] ~= OldWaveID) then -- if we have a new wave ID for this table
			LOG("----- Survival MOD: Updating wave table from C:" .. x .. " ID:" .. Survival_WaveTables[x][1] .. " ( Set:" .. (Survival_WaveTables[x][1] - 1) ..") at " .. SecondsToTime(GameTime));		
		end
	end
end



-- spawns a wave of units
--------------------------------------------------------------------------
Survival_SpawnWave = function(SpawnTime)

--	LOG("----- Survival MOD: Performing a wave spawn at " .. SecondsToTime(SpawnTime));

	local WaveTable = nil;
	local UnitTable = nil;

	local UnitID = nil;
	local OrderID = nil;
	local POS = nil;
	local RandID = nil;

	-- check the wave table times vs the wave spawn time to see which waves we spawn
	-- START AT TABLE 2 BECAUSE TABLE 1 IS SPECIAL UNITS (ARTY/NUKE)
	for x = 2, table.getn(Survival_WaveTables) do -- loop through each of the wavetable entries (ground/air/sea...)

--		LOG("----- Survival MOD: Category(" .. x .. ")     Wave Set (" .. Survival_WaveTables[x][1] - 1 .. ")   (ID: " .. Survival_WaveTables[x][1] .. ");

		-- for the amount of units we spawn in per wave
		if (table.getn(Survival_WaveTables[x][Survival_WaveTables[x][1]]) > 1) then -- only do a wave spawn if there is a wave table available
			-- for the amount of units we spawn in per wave
			for z = 1,Survival_UnitCountPerWave do
			
				WaveTable = Survival_WaveTables[x][Survival_WaveTables[x][1]]; -- grab the wave set table we're spawning from
				RandID = math.random(2, table.getn(WaveTable)); -- pick a random unit table from within this wave set
				UnitTable = WaveTable[RandID]; -- reference that unit table
				OrderID = 2;
				UnitID = Survival_GetUnitFromTable(UnitTable); -- pick a random unit id from this table
				POS = Survival_GetPOS(UnitTable[2], 0);

				Survival_SpawnUnit(UnitID, "ARMY_SURVIVAL_ENEMY", POS, OrderID);
			end
		end
	end
end



-- spawns a specified unit
--------------------------------------------------------------------------
Survival_SpawnUnit = function(UnitID, ArmyID, POS, OrderID) -- blueprint, army, position, order

--	LOG("----- Survival MOD: SPAWNUNIT: Start function...");
	local PlatoonList = {};

	local NewUnit = createSurvivalUnit(UnitID, POS[1], POS[2], POS[3])

	NewUnit:SetProductionPerSecondEnergy(325);

	table.insert(PlatoonList, NewUnit); -- add unit to a platoon
	Survival_PlatoonOrder(ArmyID, PlatoonList, OrderID); -- give the unit orders

end



-- spawns a wave of special units
--------------------------------------------------------------------------
Survival_SpawnSpecialWave = function(SpawnTime)

	local UnitTable = Survival_WaveTables[1][Survival_WaveTables[1][1]][2]
	local UnitID = nil;
	local POS = nil;

	if (table.getn(Survival_WaveTables[1][Survival_WaveTables[1][1]]) > 1) then -- only do a wave spawn if there is a wave table available

		-- spawn one per player (up to the amount of spawn locations)
		for x = 1, Survival_PlayerCount do

			UnitID = Survival_GetUnitFromTable(UnitTable); -- pick a random unit id from this table
			POS = Survival_GetPOS(UnitTable[2], 0);

			if (POS ~= nil) then
				Survival_SpawnSpecialUnit(UnitID, "ARMY_SURVIVAL_ENEMY", POS)
			end
		end
	end

end



-- spawns a special unit
-- this is fairly hard-coded for this specific setup and will need to be adjusted for alternate rules and gameplay
--------------------------------------------------------------------------
Survival_SpawnSpecialUnit = function(UnitID, ArmyID, POS) -- blueprint, army, position

	LOG("----- Survival MOD: SPAWNSPECIALUNIT: Start function...")

	local PlatoonList = {}

	local NewUnit = CreateUnitHPR(UnitID, ArmyID, POS[1], POS[2], POS[3], 0,0,0)

	NewUnit:SetReclaimable(false)
	NewUnit:SetCapturable(false)
	NewUnit:SetProductionPerSecondEnergy(25000)
	NewUnit:SetConsumptionPerSecondEnergy(0)
	NewUnit:SetProductionPerSecondMass(1000)

	NewUnit:SetMaxHealth(25000000)
	NewUnit:SetHealth(nil, 25000000)
	NewUnit:SetRegenRate(5000000)

	table.insert(PlatoonList, NewUnit)

	-- if this is an artillery unit
	if ((UnitID == "UAB2302") or (UnitID == "URB2302") or (UnitID == "UEB2302") or (UnitID == "XSB2302") or (UnitID == "UEB2401") or (UnitID == "XAB2307") or (UnitID == "URL0401")) then

		table.insert(Survival_AtyUnits, NewUnit); -- add unit to special unit list
		NewUnit:SetIntelRadius('Vision', 1000);

	elseif ((UnitID == "UAB2305") or (UnitID == "UEB2305") or (UnitID == "XSB2305") or (UnitID == "XSB2401")) then

		table.insert(Survival_NukeUnits, NewUnit); -- add unit to special unit list

		if (Survival_NextNukeTime == 10000) then
			Survival_NextNukeTime = Survival_CurrentTime; -- update counter for next time
		end

		Survival_FireNuke();
	end

	entropyLib.newUnitRevealer(getPlayerArmies()).revealUnit(NewUnit, 14)
end



-- launches a nuke from a random silo
--------------------------------------------------------------------------
Survival_FireNuke = function()

	LOG("----- Survival MOD: FIRENUKE: Start function...");

	local RandID = 1;

	if (Survival_CurrentTime >= Survival_NextNukeTime) then

		LOG("----- Survival MOD: FIRENUKE: CurrentTime > NextNukeTime...");

		if (table.getn(Survival_NukeUnits) >= 1) then

			LOG("----- Survival MOD: FIRENUKE: table.getn >= 1...");

			RandID = math.random(1, table.getn(Survival_NukeUnits)); -- pick a random nuke launcher
			Survival_NukeUnits[RandID]:GiveNukeSiloAmmo(1); -- give it 1 ammo
			IssueNuke({Survival_NukeUnits[RandID]}, ScenarioUtils.MarkerToPosition('SURVIVAL_CENTER_1' ) );

			Survival_NextNukeTime = Survival_CurrentTime + Survival_NukeFrequency; -- update counter for next time
		end
	end
end


-- returns a random unit from within a specified unit table
--------------------------------------------------------------------------
Survival_GetUnitFromTable = function(UnitTable)

	local RandID = math.random(3, table.getn(UnitTable));
	local UnitID = UnitTable[RandID];

	return UnitID;

end



-- returns a random spawn position
--------------------------------------------------------------------------
Survival_GetPOS = function(MarkerType, Randomization)

	local RandID = 1;
--	local MarkerName = nil;

	RandID = math.random(1, table.getn(Survival_MarkerRefs[MarkerType]));  -- get a random value from the selected marker count
--	LOG("----- Survival MOD: GetPOS: RandID[" .. RandID .. "]");

	if (RandID == 0) then
		return nil;
	end

 	local POS = Survival_MarkerRefs[MarkerType][RandID].position;
 
 	if (MarkerType == 4) then
 		table.remove(Survival_MarkerRefs[4], RandID);
 	elseif (MarkerType == 5) then
 		table.remove(Survival_MarkerRefs[5], RandID);
 	end

	return POS

end



-- test platoon order function
--------------------------------------------------------------------------
Survival_PlatoonOrder = function(ArmyID, UnitList, OrderID)	

--	LOG("----- Survival MOD: PLATOON: Start function...");

	if (UnitList == nil) then
		return;
	end

	local aiBrain = GetArmyBrain(ArmyID); --"ARMY_SURVIVAL_ENEMY");
	local aiPlatoon = aiBrain:MakePlatoon('','');
	aiBrain:AssignUnitsToPlatoon(aiPlatoon, UnitList, 'Attack', 'None'); -- platoon, unit list, "mission" and formation

 	-- 1 center / 2 waypoint / 3 spawn
 
 	if (OrderID == 4) then -- attack move / move

		-- attack move to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:AggressiveMoveToLocation(POS);

		-- move to random center
		POS = Survival_GetPOS(1, 25);
		aiPlatoon:MoveToLocation(POS, false);

 	elseif (OrderID == 3) then -- patrol paths

		-- move to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:MoveToLocation(POS, false);

		-- patrol to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:Patrol(POS);

	elseif (OrderID == 2) then -- attack move

		-- attack move to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:AggressiveMoveToLocation(POS);

		-- attack move to random center
		POS = Survival_GetPOS(1, 25);
		aiPlatoon:AggressiveMoveToLocation(POS);

	else -- default/order 1 is move

		-- move to random path
		POS = Survival_GetPOS(2, 25);
		aiPlatoon:MoveToLocation(POS, false);

		-- move to random center
		POS = Survival_GetPOS(1, 25);
		aiPlatoon:MoveToLocation(POS, false);
	end

end



-- calculates how many units to spawn per wave
--------------------------------------------------------------------------
function Survival_CalcWaveCounts()

	local WaveMultiplier = ScenarioInfo.Options.opt_Survival_WaveFrequency / 60;
	Survival_UnitCountPerMinute = ScenarioInfo.Options.opt_Survival_EnemiesPerMinute * Survival_PlayerCount;
	Survival_UnitCountPerWave = Survival_UnitCountPerMinute * WaveMultiplier;
	LOG("----- Survival MOD: CalcWaveCounts = ((" .. ScenarioInfo.Options.opt_Survival_EnemiesPerMinute .. " EPM * " .. Survival_PlayerCount .. " Players = " .. Survival_UnitCountPerMinute .. ")) * ((" .. ScenarioInfo.Options.opt_Survival_WaveFrequency .. " Second Waves / 60 = " .. WaveMultiplier .. ")) = " .. Survival_UnitCountPerWave .. " Units Per Wave     (( with Waves Per Minute of " .. (60 / ScenarioInfo.Options.opt_Survival_WaveFrequency) .. " = " .. (Survival_UnitCountPerWave * (60 / ScenarioInfo.Options.opt_Survival_WaveFrequency)) .. " of " .. Survival_UnitCountPerMinute .. " Units Per Minute.");
--	LOG("----- Survival MOD: CalcWaveCounts() accounts for " .. Survival_UnitCountPerWave .. " of " .. Survival_UnitCountPerMinute .. " units " .. (60 / ScenarioInfo.Options.opt_Survival_WaveFrequency) .. " times per minute.");

end



-- calculates how many units to spawn per wave
--------------------------------------------------------------------------
function Survival_CalcNukeFrequency()

	local RatioEPM = (ScenarioInfo.Options.opt_Survival_EnemiesPerMinute - 16) / 48; -- returns 0-1 based on EPM difficulty
	local RatioPC = (Survival_PlayerCount - 1) / 3; -- returns 0-1 based on player count

 	Survival_NukeFrequency = 135 - (RatioPC * 60) - (RatioEPM * 60);

	LOG("----- Survival MOD: CalcNukeFrequency = " .. " 135 - (RatioEPM: " .. RatioEPM * 60 .. "/" .. RatioEPM .. ") - (RatioPC: " .. RatioPC * 60 .. "/" .. RatioPC .. ") = " .. Survival_NukeFrequency);
--	LOG("----- Survival MOD: CalcWaveCounts() accounts for " .. Survival_UnitCountPerWave .. " of " .. Survival_UnitCountPerMinute .. " units " .. (60 / ScenarioInfo.Options.opt_Survival_WaveFrequency) .. " times per minute.");

end



-- misc functions
--------------------------------------------------------------------------


-- returns hh:mm:ss from second count
-- taken from original survival script
SecondsToTime = function(Seconds)
	return string.format("%02d:%02d", math.floor(Seconds / 60), math.mod(Seconds, 60));
end

-- gets map marker reference by name
-- taken from forum post by Saya
function GetMarker(MarkerName)
	return Scenario.MasterChain._MASTERCHAIN_.Markers[MarkerName]
end

-- returns a random spawn position
Survival_RandomizePOS = function(POS, x)

	local NewPOS = {0, 0, 0};

	NewPOS[1] = POS[1] + ((math.random() * (x * 2)) - x);
	NewPOS[3] = POS[3] + ((math.random() * (x * 2)) - x);

	return NewPOS;

end

-- gets map marker reference by name
function GetMarker(MarkerName)
	return Scenario.MasterChain._MASTERCHAIN_.Markers[MarkerName]
end

function printDamageMultiplierChange(message)
	textPrinter.print(
		string.rep(" ", 20) .. message .. " " .. formatter.formatMultiplier(ScenarioInfo.Options.opt_BeachDamageMultiplier),
		{duration = 3, location = "leftcenter"}
	)
end

function OnShiftF3()
	if ScenarioInfo.Options.opt_BeachDamageMultiplier > 0.1 then
		ScenarioInfo.Options.opt_BeachDamageMultiplier = ScenarioInfo.Options.opt_BeachDamageMultiplier - 0.1
	end

	printDamageMultiplierChange("Damage multiplier decreased to")
end

function OnShiftF4()
	ScenarioInfo.Options.opt_BeachDamageMultiplier = ScenarioInfo.Options.opt_BeachDamageMultiplier + 0.1
	printDamageMultiplierChange("Damage multiplier increased to")
end

function OnShiftF5()
	welcomeMessages.displaySettings()
end
