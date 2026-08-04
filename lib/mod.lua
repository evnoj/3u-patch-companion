local mod = require 'core/mods'
local util = require 'util'

function tup()
  include 'tools/tools'
end

-- local mft -- midi fighter twister midi device
param_callbacks_3u = {}
-- holds the voltage value of a crow output after a crow.output[n].query()
-- need to init values because of tangled async code, should refactor to avoid this
crow_outputs = {0, 0, 0, 0}

params.params_add_saved_by_3u = params.add
function params:add(p)
  local p_action_saved = p.action

  if p.action then
    p.action = function(val)
      p_action_saved(val)

      for _,func in ipairs(param_callbacks_3u[p.id]) do
        func(val)
      end
    end
  else
    p.action = function(val)
      for _,func in ipairs(param_callbacks_3u[p.id]) do
        func(val)
      end
    end
  end

  if p.id then
    param_callbacks_3u[p.id] = {}
  end

  self:params_add_saved_by_3u(p)
end

function darken_buffer(buf, level)
  level = level or 1
  local t = {}
  for i = 1, #buf do
      local byte = buf:byte(i) - level
      t[i] = string.char(byte < 0 and 0 or byte)
  end
  return table.concat(t)
end

mod.hook.register("script_pre_init", "3u patch companion pre init", function()
  local pfuncs = include('3u-patch-companion/lib/pfuncs')

  -- allows having a param that maps to params, to have a param for what param the keys and encoders control
  mappable_params_3u = {}

  -- paste the following into kakoune prompt to get number of params
  -- doesn't work anymore since i'm creating some params programmatically
  -- exec \%sparams:add\(<ret>:echo<space>%val{selection_count}<ret>
  params:add_group("3u_patch_params", "3U PATCH", 92)

  params:add_separator("clock_params_3u", "clock n basics")

  -- allows keys and encoders to be mapped to nothing
  local empty_param = {
    id="empty_param_3u",
    name="none",
    type="number",
    min=0,
    max=0
  }
  table.insert(mappable_params_3u, empty_param)
  params:add(empty_param)
  params:hide(empty_param.id)
  _menu.rebuild_params()

  local reset_ansible = {
    id="reset_ansible",
    name="reset ansible",
    type="binary",
    behavior="trigger",
    action=function(x)
      crow.ii.txo.tr_pulse(2)
    end
  }
  table.insert(mappable_params_3u, reset_ansible)
  params:add(reset_ansible)

  local bang_params = {
    id="bang_params",
    name="bang",
    type="binary",
    behavior="trigger",
    action=function() params:bang() end
  }
  params:add(bang_params)

  function update_txo_clocks(beat_sec)
    for i=1,4 do
      local base_id = "clock_txo_tr_"..i
      if params:get(base_id) == 1 then
        local m = beat_sec * 1000 / params:get(base_id.."_div")
        crow.ii.txo.tr_m(i, m)
      end
    end
  end

  -- clock division at which to sync txo metronome
  -- enables runtime control
  -- for smaller division at lower clock speeds where drift was an issue
  -- integer, bigger = faster, ex. 16 is clock.sync(1/16)
  txo_m_sync_div_3u = 1

  -- these clock params just expose relevant clock params next to the other params
  local clock_bpm = {
    id="clock_bpm",
    name="bpm @",
    type="control",
    controlspec=controlspec.def{
      min = 10,
      max = 640,
      warp = 'exp',
      step = 0.1,
      default = norns.state.clock.tempo,
      quantum = 0.2/630,
      wrap = false
    },
    formatter=function(param)
      local bpm = param:get()
      return string.format("%.1f ◀ %.1f ▶ %.1f", bpm / 2, bpm, bpm * 2)
    end,
    action=function(x)
      params:set("clock_tempo", x)
      -- must calculate manually because clock.get_beat_sec() doesn't update immediately
      local beat_sec = 60.0 / x
      local sync_sec = clock.get_beat_sec() / txo_m_sync_div_3u
      if sync_sec > 1 then
        txo_m_sync_div_3u = txo_m_sync_div_3u * 2
      elseif sync_sec < 0.5 then
        txo_m_sync_div_3u = txo_m_sync_div_3u / 2
      end
      update_txo_clocks(beat_sec)
    end
  }
  table.insert(mappable_params_3u, clock_bpm)
  params:add(clock_bpm)

  -- local clock_bpm_x2 = {
  --   id="clock_bpm_x2",
  --   name="clock bpm x2",
  --   type="control",
  --   controlspec=controlspec.def{
  --     min = 1,
  --     max = 600,
  --     warp = 'lin',
  --     step = 0.1,
  --     default = norns.state.clock.tempo,
  --     quantum = 0.1/599,
  --     wrap = false
  --   },
  --   formatter=function(val)
  --     local bpm = params:get("clock_tempo")
  --     params:set("clock_bpm_x2", bpm)
  --     return bpm
  --   end,
  --   action=function(x)
  --     local bpm = params:get("clock_tempo")
  --     if x < bpm then
  --       bpm = bpm / 2
  --       params:set("clock_bpm", bpm)
  --       params:set("clock_bpm_x2", bpm)
  --     elseif x > bpm then -- increase
  --       bpm = bpm * 2
  --       params:set("clock_bpm", bpm)
  --       params:set("clock_bpm_x2", bpm)
  --     end
  --   end
  -- }
  local clock_bpm_x2 = {
    id="clock_bpm_x2",
    name="bpm x2 @",
    type="number",
    min=-1,
    max=1,
    default=0,
    formatter=function(val)
      local bpm = params:get("clock_tempo")
      -- params:set("clock_bpm_x2", bpm)
      return bpm
    end,
    action=function(x)
      local bpm = params:get("clock_tempo")

      if x == -1 then
        bpm = bpm / 2
        params:set("clock_bpm", bpm)
        params:set("clock_bpm_x2", 0)
      elseif x == 1 then
        bpm = bpm * 2
        params:set("clock_bpm", bpm)
        params:set("clock_bpm_x2", 0)
      end
    end
  }
  params:add(clock_bpm_x2)

  function make_txo_m_toggle_func(port)
    return function(z)
      local base_id = "clock_txo_tr_"..port
      local base_name = "clock txo "..port

      if z == 1 then
        -- crow.ii.txo.tr_time(3, 60/(2*clock.get_tempo()*params:get("clock_txo_3_div"))*1000)
        crow.ii.txo.tr_time(port, 10)
        crow.ii.txo.tr_m(port, clock.get_beat_sec() * 1000 / params:get(base_id.."_div"))
        crow.ii.txo.tr_m_act(port, 1)
        if (not clock_txo_m_id) then
          clock_txo_m_id = clock.run(function()
            while true do
              clock.sync(1/txo_m_sync_div_3u)
              -- crow.output[2].volts = 6
              -- crow.output[2].volts = 0
              crow.ii.txo.m_sync(1)
            end
          end)
        end

        params:lookup_param(base_id).name = "● "..base_name
        params:show(base_id.."_div")
        params:show(base_id.."_div_x2")
        _menu.rebuild_params()
      else
        crow.ii.txo.tr_m_act(port, 0)
        if (clock_txo_m_id and
          params:get("clock_txo_tr_1") == 0 and
          params:get("clock_txo_tr_2") == 0 and
          params:get("clock_txo_tr_3") == 0 and
          params:get("clock_txo_tr_4") == 0) then
          clock.cancel(clock_txo_m_id)
          clock_txo_m_id = nil
        end

        params:lookup_param(base_id).name = "○ "..base_name
        params:hide(base_id.."_div")
        params:hide(base_id.."_div_x2")
        _menu.rebuild_params()
      end
    end
  end

  function make_txo_m_div_func(port)
    return function(div)
      crow.ii.txo.tr_m(port, clock.get_beat_sec() * 1000 / div)
    end
  end

  for i=1,4 do
    local base_id = "clock_txo_tr_"..i
    local div_id = base_id.."_div"
    local base_name = "clock txo "..i

    local base_param = {
      id=base_id,
      name="○ "..base_name,
      type="binary",
      behavior="toggle",
      default=0,
      action=make_txo_m_toggle_func(i)
    }
    if i == 3 or i == 4 then
      base_param.default = 1
    end
    table.insert(mappable_params_3u, base_param)
    params:add(base_param)

    div_param = {
      id=base_id.."_div",
      name=base_name.." div",
      type="number",
      min=1,
      max=128,
      default=16,
      action=make_txo_m_div_func(i)
    }
    table.insert(mappable_params_3u, div_param)
    params:add(div_param)
    if params:get(base_id) == 0 then
        params:hide(base_id.."_div")
        _menu.rebuild_params()
    end

    div_x2_param = {
      id=div_id.."_x2",
      name=base_name.." div x2",
      type="number",
      min=1,
      max=128,
      default=params:get(div_id),
      formatter=function(val)
        local div = params:get(div_id)
        params:set(div_id.."_x2", div)
        return div
      end,
      action=function(x)
        local div = params:get(div_id)
        -- decrease
        if x < div then
          div = math.floor(div/2)
          div = math.max(1, math.min(128, div))
          params:set(div_id, div)
          params:set(div_id.."_x2", div)
        elseif x > div then -- increase
          div = div*2
          div = math.max(1, math.min(128, div))
          params:set(div_id, div)
          params:set(div_id.."_x2", div)
        end
      end
    }

    table.insert(mappable_params_3u, div_x2_param)
    params:add(div_x2_param)
    if params:get(base_id) == 0 then
      params:hide(base_id.."_div")
      _menu.rebuild_params()
    end
  end

  local txo_cv_3_note = {
    id="txo_cv_3_note",
    name="txo cv 3 note",
    type="number",
    min=-60,
    max=60,
    default=0,
    action=function(n)
      crow.ii.txo.cv_n(3, n)
    end
  }
  params:add(txo_cv_3_note)

  local txo_cv_3_oct = {
    id="txo_cv_3_oct",
    name="txo cv 3 oct",
    type="number",
    min=-1,
    max=1,
    default=0,
    formatter=function(p)
      return params:get("txo_cv_3_note")
    end,
    action=function(d)
      -- local n = params:get("txo_cv_3_note")
      -- if d == 1 then
      --   n = n+12
      -- elseif d == -1 then
      -- end
      params:set("txo_cv_3_note", params:get("txo_cv_3_note") + (d*12))
      params:lookup_param("txo_cv_3_oct").value = 0
      -- crow.ii.txo.cv_n(3, 12 * x)
    end
  }
  params:add(txo_cv_3_oct)

  local txo_cv_3_fifths_octs = {
    id="txo_cv_3_fifths_octs",
    name="txo cv 3 fifths octs",
    type="number",
    min=-1,
    max=1,
    default=0,
    formatter=function(p)
      return params:get("txo_cv_3_note")
    end,
    action=function(d)
      if d == 0 then
        return
      end

      local n = params:get("txo_cv_3_note")
      if n < 0 then
        local oct = math.ceil(n / 12)
        local oct_n = oct * 12
        local off = n - oct_n

        if off == 0 then
          if d == 1 then
            n = oct_n + 5
          else
            n = oct_n - 7
          end
        elseif off == -7 then
          if d == 1 then
            n = oct_n
          else
            n = oct_n - 12
          end
        elseif off > -7 then
          if d == 1 then
            n = oct_n
          else
            n = oct_n - 7
          end
        elseif off < -7 then
          if d == 1 then
            n = oct_n - 7
          else
            n = oct_n - 12
          end
        end
      elseif n > 0 then
        local oct = math.floor(n / 12)
        local oct_n = oct * 12
        local off = n - oct_n

        if off == 0 then
          if d == 1 then
            n = oct_n + 7
          else
            n = oct_n - 5
          end
        elseif off == 7 then
          if d == 1 then
            n = oct_n + 12
          else
            n = oct_n
          end
        elseif off < 7 then
          if d == 1 then
            n = oct_n + 7
          else
            n = oct_n
          end
        elseif off > 7 then
          if d == 1 then
            n = oct_n + 12
          else
            n = oct_n + 7
          end
        end
      else -- n == 0
        if d == 1 then
          n = 7
        else
          n = -7
        end
      end

      params:set("txo_cv_3_note", n)
      params:lookup_param("txo_cv_3_fifths_octs").value = 0
    end
  }
  params:add(txo_cv_3_fifths_octs)

  -- this one is for mapping controllers to
  local txo_cv_3_oct_delta = {
    id="txo_cv_3_oct_delta",
    name="txo cv 3 oct",
    type="number",
    min=-3,
    max=3,
    default=0,
    action = function(x)
      local txo_cv_3_oct_v = params:get("txo_cv_3_oct")

      if x == 3 and txo_cv_3_oct_v < 5 then
        params:delta("txo_cv_3_oct", 1)
        params:set("txo_cv_3_oct_delta", 0)
        return
      elseif x == -3 and txo_cv_3_oct_v > -5 then
        params:delta("txo_cv_3_oct", -1)
        params:set("txo_cv_3_oct_delta", 0)
        return
      end
      txo_cv_3_oct_v = params:get("txo_cv_3_oct")

      if params:get("draw_changes") == 1 and
      (redraw == _script_redraw or redraw == _mod_redraw) then
        moon_map = {}
        moon_map[-5] = -9
        moon_map[-4] = -7
        moon_map[-3] = -5
        moon_map[-2] = -4
        moon_map[-1] = -2
        moon_map[0] = 0
        moon_map[1] = 2
        moon_map[2] = 4
        moon_map[3] = 5
        moon_map[4] = 7
        moon_map[5] = 9

        -- some alpha values cause strange results with level_a
        moon_alpha_map = {}
        moon_alpha_map[1] = .1
        moon_alpha_map[2] = .2
        moon_alpha_map[3] = .25
        moon_alpha_map[4] = .4
        moon_alpha_map[5] = .5
        moon_alpha_map[6] = .65
        moon_alpha_map[7] = .75
        moon_alpha_map[8] = .8
        moon_alpha_map[9] = .9
        moon_alpha_map[10] = 1
        moon_alpha_map[11] = 1

        moon_loc = {
          x = 110,
          y = 1,
          w = 12
        }

        if moon_metro then
          metro.free(moon_metro.id)
        end
        moon_fade_counter = 0
        moon_metro = metro.init(function()
          if moon_fade_counter > 20 then
            restore_redraw(_script_redraw)
            metro.free(moon_metro.id)
            moon_metro = nil
            params:lookup_param("txo_cv_3_oct_delta").value = 0
            return
          else
            moon_fade_counter = moon_fade_counter + 1
          end
        end, 1/10)
        moon_metro:start()
        moon_fade_alpha = moon_fade_alpha or .5
        -- print("delta "..d)

        redraw = function()
          _script_redraw()

          screen.level(0)
          screen.rect(moon_loc.x-1, moon_loc.y-1, moon_loc.w+2, moon_loc.w + 5)
          screen.fill()

          screen.display_png(_path.code.."3u-patch-companion/pngs/moon"
                            ..tostring(moon_map[txo_cv_3_oct_v])
                            ..".png", moon_loc.x, moon_loc.y)

          screen.level(15)
          local delta = params:get("txo_cv_3_oct_delta")
          if delta == 2 then
            screen.pixel(moon_loc.x + 7, moon_loc.y + 13)
            screen.pixel(moon_loc.x + 10, moon_loc.y + 13)
          elseif delta == 1 then
            screen.pixel(moon_loc.x + 7, moon_loc.y + 13)
          elseif delta == -1 then
            screen.pixel(moon_loc.x + 4, moon_loc.y + 13)
          elseif delta == -2 then
            screen.pixel(moon_loc.x + 4, moon_loc.y + 13)
            screen.pixel(moon_loc.x + 1, moon_loc.y + 13)
          end
          screen.fill()

          if moon_fade_counter > 10 then
            screen.level_a(0, moon_alpha_map[moon_fade_counter - 10])
            screen.rect(moon_loc.x-1, moon_loc.y-1, moon_loc.w+2, moon_loc.w + 5)
            screen.fill()
          end

          screen.update()
        end
        _mod_redraw = redraw
      end
    end
  }
  table.insert(mappable_params_3u, txo_cv_3_oct_delta)
  params:add(txo_cv_3_oct_delta)
  params:hide("txo_cv_3_oct_delta")
  _menu.rebuild_params()

  params:add_separator("crow_env_params_3u", "crow env")

  local crow_env_active = {
    id="crow_env_active",
    name="○ crow env",
    type="binary",
    behavior="toggle",
    default=1,
    action= function(state)
      -- prevent the env params from attempting to set crow public var before they are available
      crow_env_init_3u = false

      -- local function for clock.run
      local function dofunc(z)
        local out = params:get("crow_env_out")
        local input = params:get("crow_env_in")

        if z == 1 then
        -- if z == 1 and not crow_env_init_3u then
          norns.crow.loadscript("3u-patch-companion/crow/env-public-vars.lua")
          -- loadscript is async, and takes time run
          -- we need to ensure the load is finished before continuing
          -- TODO: find out how to make loadscript synchronous
          clock.sleep(1)
          -- script is loaded, allow env params to set public vars
          crow_env_init_3u = true

          local amp = params:get("crow_env_amp")
          local retrig = params:string("crow_env_retrig_behavior")
          local time = params:get("crow_env_time")
          local ratio = params:get("crow_env_ratio")
          local rise = time * ratio
          local fall = time * (1 - ratio)
          local rise_shape = params:string("crow_env_rise_shape")
          local fall_shape = params:string("crow_env_fall_shape")
          local start_stage = ""

          crow.public.envout = out

          if retrig == "from zero" then
            start_stage="to(0, 0),"
          end

          crow.output[out].action = "{ "..start_stage.."to(dyn{amp="..amp.."}, dyn{rise="..rise.."}, '"..rise_shape.."'), to(0, dyn{fall="..fall.."}, '"..fall_shape.."') }"

          crow.output[out].done = function()
            crow.public.envactive = 0
          end

          crow.output[out].receive = function(v) crow_outputs[out] = v end
          crow.output[out].query()

          crow.input[input].mode('change', 1, 0.1, 'rising')

          if retrig == "no retrig" then
            crow.input[input].change = function()
              if crow.public.envactive == 0 then
                crow.public.envactive = 1
                crow.output[crow.public.envout]()
                enc_10_11_env_animate(nil, nil)
              end
            end
          else
            crow.input[input].change = function()
              crow.public.envactive = 1
              crow.output[crow.public.envout]()
              enc_10_11_env_animate(nil, nil)
            end
          end

          params:lookup_param("crow_env_active").name = "● crow env"
          params:show("crow_env_time")
          params:show("crow_env_ratio")
          params:show("crow_env_amp")
          params:show("crow_env_retrig_behavior")
          params:show("crow_env_in")
          params:show("crow_env_out")
          _menu.rebuild_params()

          -- there is some kind of ii init that happens when we do the crow stuff above
          -- it clears my values for ii devices like wsyn
          -- need to bang to send the ii messages again
          for _,p in pairs(params.params) do
            if string.match(p.id, "^wsyn") or string.match(p.id, "^txo") then
              p:bang()
            end
          end
        elseif z == 0 then
          -- reset offset
          crow.cal.output[out].offset = crow_base_offset[out]

          params:lookup_param("crow_env_active").name = "○ crow env"
          params:hide("crow_env_time")
          params:hide("crow_env_ratio")
          params:hide("crow_env_amp")
          params:hide("crow_env_retrig_behavior")
          params:hide("crow_env_in")
          params:hide("crow_env_out")
          _menu.rebuild_params()
        end
      end

      clock.run(dofunc, state)
    end
  }
  params:add(crow_env_active)

  local crow_env_time = {
    id="crow_env_time",
    name="crow env time",
    type="control",
    controlspec=controlspec.def{
      min = 0.01,
      max = 8,
      warp = 'exp',
      step = 0.01,
      default = 2,
      quantum = 0.01/(4-0.01),
      wrap = false
    },
    action=function(time)
      if crow_env_init_3u then
        local ratio = params:get("crow_env_ratio")
        local rise = time * ratio + 0.0005
        local fall = time * (1 - ratio)
        local out = params:get("crow_env_out")
        crow.output[out].dyn.rise = rise
        crow.output[out].dyn.fall = fall
      end
    end
  }
  params:add(crow_env_time)
  if params:get("crow_env_active") == 0 then
    params:hide(crow_env_time)
    _menu.rebuild_params()
  end

  local crow_env_ratio = {
    id="crow_env_ratio",
    name="crow env ratio",
    type="control",
    controlspec=controlspec.def{
      min = 0,
      max = 1,
      warp = 'lin',
      step = 0.001,
      default = 0.1,
      quantum = 0.001,
      wrap = false
    },
    action=function(ratio)
      if crow_env_init_3u then
        -- if ratio == 0 then
          -- don't set ratio to true zero, this way ensures the envelope drops
          -- to zero when using the "from zero" retrig behavior
          -- ratio = 0.001
        -- end
        local time = params:get("crow_env_time")
        -- don't set rise to true zero, this way ensures the envelope drops
        -- to zero when using the "from zero" retrig behavior
        local rise = time * ratio + 0.0005
        local fall = params:get("crow_env_time") * (1 - ratio)
        local out = params:get("crow_env_out")
        crow.output[out].dyn.rise = rise
        crow.output[out].dyn.fall = fall
      end
    end,
    formatter=function(param) return string.format("%.3f", param:get()) end
  }
  params:add(crow_env_ratio)
  if params:get("crow_env_active") == 0 then
    params:hide("crow_env_ratio")
    _menu.rebuild_params()
  end

  -- my values for the cal offset of the outputs
  -- need to figure out how to read these from norns
  crow_base_offset = {}
  crow_base_offset[1] = 0.02296516
  crow_base_offset[2] = -0.005275138
  crow_base_offset[3] = -0.003352082
  crow_base_offset[4] = -0.003550681

  local crow_env_offset ={
    id="crow_env_offset",
    name="crow env offset",
    type="control",
    controlspec=controlspec.def{
      min = 0,
      max = 10,
      warp = 'lin',
      step = 0.1,
      default = 0,
      quantum = 0.1/10,
      wrap = false
    },
    action=function(offset)
      -- if crow_env_init_3u then
        local out = params:get("crow_env_out")
        crow.cal.output[out].offset = crow_base_offset[out] + offset
      -- end
    end
  }
  params:add(crow_env_offset)
  if params:get("crow_env_active") == 0 then
    params:hide("crow_env_offset")
    _menu.rebuild_params()
  end


  local crow_env_amp = {
    id="crow_env_amp",
    name="crow env amp",
    type="control",
    controlspec=controlspec.def{
      min = -5,
      max = 10,
      warp = 'lin',
      step = 0.1,
      default = 8,
      quantum = 0.1/15,
      wrap = false
    },
    action=function(amp)
      if crow_env_init_3u then
        local out = params:get("crow_env_out")
        crow.output[out].dyn.amp = amp
      end
    end
  }
  params:add(crow_env_amp)
  if params:get("crow_env_active") == 0 then
    params:hide("crow_env_amp")
    _menu.rebuild_params()
  end

  local crow_env_rise_shape = {
    id="crow_env_rise_shape",
    name="crow env rise shape",
    type="option",
    options={"linear", "exponential", "logarithmic", "sine"},
    action=function()
      if crow_env_init_3u then
        local out = params:get("crow_env_out")
        local amp = params:get("crow_env_amp")
        local len = params:get("crow_env_time")
        local ratio = params:get("crow_env_ratio")
        local rise = len * ratio
        local fall = len * (1 - ratio)
        local rise_shape = params:string("crow_env_rise_shape")
        local fall_shape = params:string("crow_env_fall_shape")
        local retrig = params:string("crow_env_retrig_behavior")
        local start_stage = ""

        if retrig == "from zero" then
          start_stage="to(0, 0),"
        end

        crow.output[out].action = "{ "..start_stage.."to(dyn{amp="..amp.."}, dyn{rise="..rise.."}, '"..rise_shape.."'), to(0, dyn{fall="..fall.."}, '"..fall_shape.."') }"
      end
    end
  }
  params:add(crow_env_rise_shape)
  if params:get("crow_env_active") == 0 then
    params:hide("crow_env_rise_shape")
    _menu.rebuild_params()
  end

  local crow_env_fall_shape = {
    id="crow_env_fall_shape",
    name="crow env fall shape",
    type="option",
    options={"linear", "exponential", "logarithmic", "sine"},
    action=function()
      if crow_env_init_3u then
        local out = params:get("crow_env_out")
        local amp = params:get("crow_env_amp")
        local len = params:get("crow_env_time")
        local ratio = params:get("crow_env_ratio")
        local rise = len * ratio
        local fall = len * (1 - ratio)
        local rise_shape = params:string("crow_env_rise_shape")
        local fall_shape = params:string("crow_env_fall_shape")
        local retrig = params:string("crow_env_retrig_behavior")
        local start_stage = ""

        if retrig == "from zero" then
          start_stage="to(0, 0),"
        end

        crow.output[out].action = "{ "..start_stage.."to(dyn{amp="..amp.."}, dyn{rise="..rise.."}, '"..rise_shape.."'), to(0, dyn{fall="..fall.."}, '"..fall_shape.."') }"
      end
    end
  }
  params:add(crow_env_fall_shape)
  if params:get("crow_env_active") == 0 then
    params:hide("crow_env_fall_shape")
    _menu.rebuild_params()
  end

  local crow_env_retrig_behavior = {
    id="crow_env_retrig_behavior",
    name="crow env retrig",
    type="option",
    options={"from zero", "from current", "no retrig"},
    action=function()
      if crow_env_init_3u then
        local retrig = params:string("crow_env_retrig_behavior")
        local out = params:get("crow_env_out")
        local input = params:get("crow_env_in")
        local amp = params:get("crow_env_amp")
        local len = params:get("crow_env_time")
        local ratio = params:get("crow_env_ratio")
        local rise = len * ratio
        local fall = len * (1 - ratio)

        if retrig == "no retrig" then -- no retrig
          crow.input[input].change = function()
            if crow.public.envactive == 0 then
              crow.public.envactive = 1
              crow.output[crow.public.envout]()
            end
          end
        else
          local rise_shape = params:string("crow_env_rise_shape")
          local fall_shape = params:string("crow_env_fall_shape")
          local start_stage = ""

          -- allow retrig
          crow.input[input].change = function()
            crow.public.envactive = 1
            crow.output[crow.public.envout]()
          end

          if retrig == "from zero" then -- from current
            start_stage="to(0, 0),"
          end

          crow.output[out].action = "{ "..start_stage.."to(dyn{amp="..amp.."}, dyn{rise="..rise.."}, '"..rise_shape.."'), to(0, dyn{fall="..fall.."}, '"..fall_shape.."') }"
        end
      end
    end
  }
  params:add(crow_env_retrig_behavior)
  if params:get("crow_env_active") == 0 then
    params:hide("crow_env_retrig_behavior")
    _menu.rebuild_params()
  end

  local crow_env_in = {
    id="crow_env_in",
    name="crow env trig in",
    type="number",
    min=1,
    max=2,
    default=2,
  }
  params:add(crow_env_in)
  if params:get("crow_env_active") == 0 then
    params:hide("crow_env_in")
    _menu.rebuild_params()
  end

  local crow_env_out = {
    id="crow_env_out",
    name="crow env out",
    type="number",
    min=1,
    max=4,
    default=3,
  }
  params:add(crow_env_out)
  if params:get("crow_env_active") == 0 then
    params:hide("crow_env_out")
    _menu.rebuild_params()
  end

  local crow_clock_output_3 = {
    id="crow_clock_output_3",
    name="crow clock out 3",
    type="binary",
    behavior="toggle",
    default=0,
    action=function(x)
      if x == 1 then
        params:set("clock_crow_out", 4) -- "output 3"
      else
        params:set("clock_crow_out", 1) -- "off"
        -- pfuncs.clear_ii_voices()
      end
    end
  }
  table.insert(mappable_params_3u, crow_clock_output_3)
  params:add(crow_clock_output_3)

  -- controls the builtin CLOCK>crow>crow out div param, but by multiplying/dividing by 2 instead of incrementing by one
  local crow_clock_div_x2 = {
    id="crow_clock_div_x2",
    name="crow clock div x2",
    type="number",
    min=1,
    max=32,
    default=params:get("clock_crow_out_div"),
    formatter=function(param)
      local div = params:get("clock_crow_out_div")
      params:set("crow_clock_div_x2", div)
      return div
    end,
    action=function(x)
      local div = params:get("clock_crow_out_div")
      -- decrease
      if x < div then
        div = math.floor(div/2)
        div = math.max(1, math.min(32, div))
        params:set("clock_crow_out_div", div)
        params:set("crow_clock_div_x2", div)
      elseif x > div then -- increase
        div = div*2
        div = math.max(1, math.min(32, div))
        params:set("clock_crow_out_div", div)
        params:set("crow_clock_div_x2", div)
      end
    end
  }
  table.insert(mappable_params_3u, crow_clock_div_x2)
  params:add(crow_clock_div_x2)

  params:add_separator("wsyn_params_3u", "wsyn")

  local wsyn_curve = {
    id="wsyn_curve",
    name="wsyn curve",
    type="control",
    controlspec=controlspec.def{
          min = -5.0,
          max = 5.0,
          warp = 'lin',
          step = 0.01,
          default = 5,
          units = 'v',
          quantum = 0.005,
          wrap = false
      },
    formatter=function(param) return string.format("%.2f", param:get()) end,
    action=function(x) crow.ii.wsyn.curve(x) end
  }
  table.insert(mappable_params_3u, wsyn_curve)
  params:add(wsyn_curve)

  local wsyn_ramp = {
    id="wsyn_ramp",
    name="wsyn ramp",
    type="control",
    controlspec=controlspec.def{
          min = -5.0,
          max = 5.0,
          warp = 'lin',
          step = 0.01,
          default = 0,
          units = 'v',
          quantum = 0.005,
          wrap = false
      },
    formatter=function(param) return string.format("%.2f", param:get()) end,
    action=function(x) crow.ii.wsyn.ramp(x) end
  }
  table.insert(mappable_params_3u, wsyn_ramp)
  params:add(wsyn_ramp)

  local wsyn_fm_index = {
    id="wsyn_fm_index",
    name="wsyn fm index",
    type="control",
    controlspec=controlspec.def{
          min = 0,
          max = 4.0,
          warp = 'lin',
          step = 0.01,
          default = 0,
          units = 'v',
          -- quantum = 0.01,
          quantum = 0.0002,
          wrap = false
      },
    formatter=function(param) return string.format("%.2f", param:get()) end,
    action=function(x)
      crow.ii.wsyn.fm_index(x)
      -- patch cv output 4 to the cv in of the veils channel wsyn goes through
      -- veils slider at max, offset min, linear response
      -- closes vca as more fm applied to compensate for perceived volume increase
      local cv = 8 - (x / 4) * 3
      crow.output[4].volts = cv
      -- print("fm index: "..x..", cv: "..cv)
    end
  }
  table.insert(mappable_params_3u, wsyn_fm_index)
  params:add(wsyn_fm_index)

  -- params:add{
  --   id="wsyn vca level",
  --   type="control",
  --     controlspec=controlspec.def{
  --         min = 0,
  --         max = 4.0,
  --         warp = 'lin',
  --         step = 0.01,
  --         default = 0,
  --         units = 'v',
  --         -- quantum = 0.01,
  --         quantum = 0.0002,
  --         wrap = false
  --     },
  -- }
  -- -- should be hidden from menu, only controlled by script
  -- params:hide("wsyn vca level")
  -- _menu.rebuild_params()
  local wsyn_fm_env = {
    id="wsyn_fm_env",
    name="wsyn fm env",
    type="control",
    controlspec=controlspec.def{
          min = -5,
          max = 5,
          warp = 'lin',
          step = 0.01,
          default = 0,
          units = 'v',
          quantum = 0.005,
          wrap = false
      },
    formatter=function(param) return string.format("%.2f", param:get()) end,
    action=function(x) crow.ii.wsyn.fm_env(x) end
  }
  table.insert(mappable_params_3u, wsyn_fm_env)
  params:add(wsyn_fm_env)

  -- local wsyn_fm_ratio = {
  --   id="wsyn_fm_ratio",
  --   name="wsyn fm ratio",
  --   type="number",
  --   min=1,
  --   max=20,
  --   default=4,
  --   action=function(x) crow.ii.wsyn.fm_ratio(x) end
  -- }
  -- table.insert(mappable_params_3u, wsyn_fm_ratio)
  -- params:add(wsyn_fm_ratio)

  local function parse_fraction(fraction_str)
    local n, d = fraction_str:match("([^/]+)/([^/]+)")
    if n and d then
      return tonumber(n) / tonumber(d)
    else
      return tonumber(fraction_str)
    end
  end

  -- given a string with a fraction, returns 2 results: first the numerator, then the denominator
  local function get_fraction_n_d(fraction_str)
    local n, d = fraction_str:match("([^/]+)/([^/]+)")

    if not n then
      n = tonumber(fraction_str)
    end

    if not d then
      d = "1"
    end

    return tonumber(n), tonumber(d)
  end

  wsyn_ratios ={"19/3", "17/4", "15/4", "13/2", "13/3", "11/2", "11/3", "9/2", "7/2", "7/3", "5/2", "3/2", -- 12 elements up to here
  "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20"}
  wsyn_ratios_spicy = {8/3, 5/3, 19/4}
  local wsyn_fm_ratio =  {
    id="wsyn_fm_ratio",
    name="wsyn fm ratio",
    type="option",
    options=wsyn_ratios,
    default = 16, -- 4
    action= function(i)
      local r = parse_fraction(wsyn_ratios[i])
      local d = 2^params:get("wsyn_fm_ratio_mult_exp")
      crow.ii.wsyn.fm_ratio(r*d)
    end
  }
  table.insert(mappable_params_3u, wsyn_fm_ratio)
  params:add(wsyn_fm_ratio)

  local wsyn_fm_ratio_mult_exp_param = {
    id="wsyn_fm_ratio_mult_exp",
    name="wsyn fm ratio divider",
    type="number",
    min=-5,
    max=5,
    default = 0,
    action = function(v)
      params:lookup_param("wsyn_fm_ratio"):bang()
    end
  }
  table.insert(mappable_params_3u, wsyn_fm_ratio_mult_exp_param)
  params:add(wsyn_fm_ratio_mult_exp_param)

  -- local wsyn_fm_ratio_controller = {
  --   id="wsyn_fm_ratio_controller",
  --   name="wsyn fm ratio",

  -- }

  local wsyn_lpg_symmetry = {
    id="wsyn_lpg_symmetry",
    name="wsyn lpg symmetry",
    type="control",
    controlspec=controlspec.def{
          min = -5,
          max = 5,
          warp = 'lin',
          step = 0.01,
          default = -3.5,
          units = 'v',
          quantum = 0.005,
          wrap = false
      },
    formatter=function(param) return string.format("%.2f", param:get()) end,
    action=function(x) crow.ii.wsyn.lpg_symmetry(x) end
  }
  table.insert(mappable_params_3u, wsyn_lpg_symmetry)
  params:add(wsyn_lpg_symmetry)

  local wsyn_lpg_time = {
    id="wsyn_lpg_time",
    name="wsyn lpg time",
    type="control",
    controlspec=controlspec.def{
          min = -4,
          max = 4,
          warp = 'lin',
          step = 0.01,
          default = -2.7,
          units = 'v',
          quantum = 0.0002,
          wrap = false
      },
    formatter=function(param) return string.format("%.2f", param:get()) end,
    action=function(x) crow.ii.wsyn.lpg_time(x) end
  }
  table.insert(mappable_params_3u, wsyn_lpg_time)
  params:add(wsyn_lpg_time)

  function make_txo_voice_show_function(port)
    return function(z)
      local base_id = "txo_voice_"..port
      local show_id = base_id.."_show"
      local base_name = "txo voice "..port

      if z == 1 then
        params:lookup_param(show_id).name = "▼ "..base_name
        params:show(base_id.."_shape")
        params:show(base_id.."_level")
        params:show(base_id.."_attack")
        params:show(base_id.."_decay")
        _menu.rebuild_params()
      else
        params:lookup_param(show_id).name = "▶ "..base_name
        params:hide(base_id.."_shape")
        params:hide(base_id.."_level")
        params:hide(base_id.."_attack")
        params:hide(base_id.."_decay")
        _menu.rebuild_params()
      end
    end
  end

  function make_txo_voice_level_func(port)
    return function(x)
      crow.ii.txo.cv(port, x)
    end
  end

  function make_txo_voice_attack_func(port)
    return function(x)
      crow.ii.txo.env_att(port, x)
    end
  end

  function make_txo_voice_decay_func(port)
    return function(x)
      crow.ii.txo.env_dec(port, x)
    end
  end

  function make_txo_voice_shape_func(port)
    return function(x)
      crow.ii.txo.osc_wave(port, x)
    end
  end

  params:add_separator("txo_voice_params_3u", "txo voices")

  for i=1,4 do
    local base_id = "txo_voice_"..i
    local show_id = base_id.."_show"
    local base_name = "txo voice "..i

    local show_param = {
      id=show_id,
      name="▶ "..base_name,
      type="binary",
      behavior="toggle",
      default=0,
      action=make_txo_voice_show_function(i)
    }
    if i == 4 then
      show_param.default = 1
    end
    params:add(show_param)

    shape_param = {
      id=base_id.."_shape",
      name=base_name.." shape",
      type="control",
      controlspec=controlspec.def{
        min = 0,
        max = 5000,
        step = 10,
        default = 0,
        units = 'mv',
        quantum = 1/500,
        wrap = false
      },
      action=make_txo_voice_shape_func(i)
    }
    table.insert(mappable_params_3u, shape_param)
    params:add(shape_param)
    if params:get(show_id) == 0 then
      params:hide(base_id.."_shape")
      _menu.rebuild_params()
    end

    local level_param = {
      id=base_id.."_level",
      name=base_name.." level",
      -- type="number",
      -- min=0,
      -- max=4500,
      -- default=0,
      type="control",
      controlspec=controlspec.def{
            min = 0,
            max = 8,
            warp = 'lin',
            step = 0.01,
            default = 1,
            units = 'v',
            quantum = 0.01/8,
            wrap = false
        },
      -- formatter=function(param) return string.format("%.2f", param:get()) end,
      action=make_txo_voice_level_func(i)
    }
    table.insert(mappable_params_3u, level_param)
    params:add(level_param)
    if params:get(show_id) == 0 then
        params:hide(base_id.."_level")
        _menu.rebuild_params()
    end

    local attack_param = {
      id=base_id.."_attack",
      name=base_name.." attack",
      type="control",
      controlspec=controlspec.def{
            min = 1,
            max = 5000,
            warp = 'exp',
            step = 1,
            default = 40,
            units = 'mv',
            quantum = 0.002,
            wrap = false
        },
      -- formatter=function(param) return param:get() end,
      action=make_txo_voice_attack_func(i)
    }
    table.insert(mappable_params_3u, attack_param)
    params:add(attack_param)
    if params:get(show_id) == 0 then
      params:hide(base_id.."_attack")
      _menu.rebuild_params()
    end

    local decay_param = {
      id=base_id.."_decay",
      name=base_name.." decay",
      type="control",
      controlspec=controlspec.def{
            min = 1,
            max = 10000,
            warp = 'exp',
            step = 1,
            default = 2000,
            units = 'mv',
            quantum = 0.002,
            wrap = false
        },
      -- formatter=function(param) return param:get() end,
      action=make_txo_voice_decay_func(i)
    }
    table.insert(mappable_params_3u, decay_param)
    params:add(decay_param)
    if params:get(show_id) == 0 then
      params:hide(base_id.."_decay")
      _menu.rebuild_params()
    end
  end

  local crow_ins_to_wsyn = {
    id="crow_ins_to_wsyn",
    name="crow ins to wsyn",
    type="binary",
    behavior="toggle",
    default=0,
    action=function(x)
      if x == 1 then
        pfuncs.crow_ins_to_wsyn_start()
      else
        pfuncs.crow_ins_to_wsyn_stop()
      end
    end
  }
  table.insert(mappable_params_3u, crow_ins_to_wsyn)
  params:add(crow_ins_to_wsyn)

  params:add_separator("pedals")
  pedal_midi = midi.connect(2)
  rmc_chan = 1
  rmc_max_time = 4.19
  blooper_chan = 2
  blooper_max_time = 32

  rmc_clock_tap_id=math.maxinteger

  function rmc_send_clock_taps()
    local d = parse_fraction(params:string("rmc_division"))
    local m = 2^params:get("rmc_div_mult_exp")
    local div = d * m
    local sync_sec = clock.get_beat_sec() * div
    -- for unknown reason, need to increase the sync seconds by this much
    -- to get the expected delay time
    -- experimentally derived
    -- seems like a more accurate approach will require more experimentation and
    -- adapting based on the range of sync_sec
    sync_sec = sync_sec * 1.1

    -- seems like maybe tap tempo has an even lower max time, need to test more
    if sync_sec > rmc_max_time then
      debug_msg("tried to sync RMC with tap time of "..sync_sec..", above maximum delay time")
      add_animator(7, function()
        -- make led red
        mft:cc(7, 85 , 2)
        mft:cc(7, mft_rgb_brightness_default, 3)

        clock.sleep(1)

        -- make led regular color and turn it off
        mft:cc(7, 17, 3)
        mft:cc(7, 0 , 2)
      end)
    else
      -- make rgb led regular to indicate sync
      mft:cc(7, mft_rgb_brightness_default, 3)
      mft:cc(7, 0, 2)
    end

    if rmc_clock_tap_id then
      clock.cancel(rmc_clock_tap_id)
    end

    rmc_clock_tap_id = clock.run(function()
      for i=1,4 do
        pedal_midi:cc(93, 127, 1)
        clock.sleep(sync_sec)
      end

      -- for some reason, below approach resulted in too fast of delay times
      -- above approach works better
      -- unknown why
      -- for i=1,4 do
      --   clock.sync(div)
      --   pedal_midi:cc(93, 127, rmc_chan)
      -- end
    end)

    rmc_clock_tap_id = nil
  end

  -- if clock changes while sending clock taps, start over
  table.insert(param_callbacks_3u['clock_bpm'], function(bpm)
    if rmc_clock_tap_id then
      rmc_send_clock_taps()
    end
  end)

  local rmc_send_clock_taps_param = {
    id="rmc_send_clock_taps",
    name="rmc send clock taps @",
    type="binary",
    behavior="trigger",
    action=function(x)
      rmc_send_clock_taps()
    end,
  }
  table.insert(mappable_params_3u, rmc_send_clock_taps_param)
  params:add(rmc_send_clock_taps_param)

  rmc_divisions={"1/2", "2/3", "3/4", "4/5", "5/6", "1", "6/5", "5/4", "4/3", "3/2", "2" }
  local rmc_division_param =  {
    id="rmc_division",
    name="rmc division",
    type="option",
    options=rmc_divisions,
    default = 6, -- 1
    action= function(i)
      local n,d = get_fraction_n_d(rmc_divisions[i])
      local mult_exp = params:get("rmc_div_mult_exp")

      if mult_exp < 0 then
        d = d * (2^(mult_exp * -1))
      elseif mult_exp > 0 then
        n = n * (2^mult_exp)
      end

      local div_str = string.format("%d", n)..""

      if d ~= 1 then
        div_str = div_str.."/"..string.format("%d", d)
      end

      params:lookup_param("rmc_send_clock_taps").name = "rmc send clock taps @ "..div_str
    end
  }
  table.insert(mappable_params_3u, rmc_division_param)
  params:add(rmc_division_param)

  local rmc_div_mult_exp_param = {
    id="rmc_div_mult_exp",
    name="rmc division multiplier",
    type="number",
    min=-5,
    max=5,
    default = 0,
    action = function(v)
      params:lookup_param("rmc_division"):bang()
    end,
    formatter = function(p)
      local exp = p.value

      if exp < 0 then
        return "1/"..string.format("%d", 2^(exp * -1))
      else
        return string.format("%d", 2^exp)
      end
    end
  }
  table.insert(mappable_params_3u, rmc_div_mult_exp_param)
  params:add(rmc_div_mult_exp_param)

  blooper_set_loop_clock_id=math.maxinteger

  function blooper_set_loop()
    local d = parse_fraction(params:string("blooper_division"))
    local m = 2^params:get("blooper_div_mult_exp")
    local div = d * m
    -- local sync_sec = clock.get_beat_sec() * div
    -- see rmc_send_clock_taps for explanation of this
    -- sync_sec = sync_sec * 1.1

    -- if sync_sec > blooper_max_time then
    --   debug_msg("tried to sync blooper with tap time of "..sync_sec..", above maximum time")
    --   add_animator(7, function()
    --     -- make led red
    --     mft:cc(6, 85 , 2)
    --     mft:cc(6, mft_rgb_brightness_default, 3)

    --     clock.sleep(1)

    --     -- make led regular color and turn it off
    --     mft:cc(6, 17, 3)
    --     mft:cc(6, 0 , 2)
    --   end)
    -- else
      -- make rgb led regular to indicate sync
      mft:cc(6, mft_rgb_brightness_default, 3)
      mft:cc(6, 0, 2)
    -- end

    if blooper_set_loop_clock_id then
      debug_msg("tried to set blooper loop, already in progress, cancelling")
      clock.cancel(blooper_set_loop_clock_id)
    end

    blooper_set_loop_clock_id = clock.run(function()
      -- pedal_midi:cc(7, 127, blooper_chan) -- erase existing loop
      clock.sync(div)
      pedal_midi:cc(1, 127, blooper_chan)
      clock.sync(div)
      -- clock.sleep(sync_sec)
      pedal_midi:cc(3, 127, blooper_chan)
    end)

    blooper_set_loop_clock_id = nil
  end

  local blooper_set_loop_param = {
    id="blooper_set_loop",
    name="blooper set loop @",
    type="binary",
    behavior="trigger",
    action=function(x)
      blooper_set_loop()
    end,
  }
  table.insert(mappable_params_3u, blooper_set_loop_param)
  params:add(blooper_set_loop_param)

  blooper_divisions={"1/2", "2/3", "3/4", "4/5", "5/6", "1", "6/5", "5/4", "4/3", "3/2", "2" }
  local blooper_division_param =  {
    id="blooper_division",
    name="blooper division",
    type="option",
    options=blooper_divisions,
    default = 6, -- 1
    action= function(i)
      local n,d = get_fraction_n_d(blooper_divisions[i])
      local mult_exp = params:get("blooper_div_mult_exp")

      if mult_exp < 0 then
        d = d * (2^(mult_exp * -1))
      elseif mult_exp > 0 then
        n = n * (2^mult_exp)
      end

      local div_str = string.format("%d", n)..""

      if d ~= 1 then
        div_str = div_str.."/"..string.format("%d", d)
      end

      params:lookup_param("blooper_set_loop").name = "blooper set loop @ "..div_str
    end
  }
  table.insert(mappable_params_3u, blooper_division_param)
  params:add(blooper_division_param)

  local blooper_div_mult_exp_param = {
    id="blooper_div_mult_exp",
    name="blooper division multiplier",
    type="number",
    min=-5,
    max=5,
    default = 0,
    action = function(v)
      params:lookup_param("blooper_division"):bang()
    end,
    formatter = function(p)
      local exp = p.value

      if exp < 0 then
        return "1/"..string.format("%d", 2^(exp * -1))
      else
        return string.format("%d", 2^exp)
      end
    end
  }
  table.insert(mappable_params_3u, blooper_div_mult_exp_param)
  params:add(blooper_div_mult_exp_param)

  -- create key and encoder action params
  key_options_3u = {}
  key_option_to_id_3u = {}
  enc_options_3u = {}
  enc_option_to_id_3u = {}
  trackball_options_3u = {}
  trackball_option_to_id_3u = {}

  table.insert(key_options_3u, "none")
  key_option_to_id_3u["none"] = "empty_param"
  -- table.insert(enc_options, "none")
  -- enc_option_to_id["none"] = "empty_param"
  -- table.insert(trackball_options, "none")
  -- trackball_option_to_id["none"] = "empty_param"

  for i,p in ipairs(mappable_params_3u) do
    if p.type == "binary" then
      table.insert(key_options_3u, p.name)
      key_option_to_id_3u[p.name] = p.id
    elseif p.type == "number" or p.type == "control" or p.type == "option" then
      table.insert(enc_options_3u, p.name)
      enc_option_to_id_3u[p.name] = p.id
      table.insert(trackball_options_3u, p.name)
      trackball_option_to_id_3u[p.name] = p.id
    end
  end

  params:add_separator("control_mappings", "control mappings")

  local trackball_x_action = {
    id="trackball_x_action",
    name="ball x",
    type="option",
    options=trackball_options_3u,
    default = pfuncs.get_index_of_value(trackball_options_3u, "wsyn fm index"),
  }
  params:add(trackball_x_action)

  local trackball_y_action = {
    id="trackball_y_action",
    name="ball y",
    type="option",
    options=trackball_options_3u,
    default = pfuncs.get_index_of_value(trackball_options_3u, "wsyn lpg time"),
  }
  params:add(trackball_y_action)

  local trackball_scroll_action = {
    id="trackball_scroll_action",
    name="ball scroll",
    type="option",
    options=trackball_options_3u,
    default = pfuncs.get_index_of_value(trackball_options_3u, "wsyn fm ratio"),
  }
  params:add(trackball_scroll_action)

  local trackball_x_invert = {
    id="trackball_x_invert",
    name="invert ball x",
    type="binary",
    behavior="toggle",
    default = 0,
  }
  params:add(trackball_x_invert)

  local trackball_y_invert = {
    id="trackball_y_invert",
    name="invert ball y",
    type="binary",
    behavior="toggle",
    default = 0,
  }
  params:add(trackball_y_invert)

  local trackball_scroll_invert = {
    id="trackball_scroll_invert",
    name="invert ball scroll",
    type="binary",
    behavior="toggle",
    default = 1,
  }
  params:add(trackball_scroll_invert)

  local k2_action = {
    id="k2_action_3u",
    name="k2",
    type="option",
    options=key_options_3u,
    default = pfuncs.get_index_of_value(key_options_3u, "none"),
    action = function(v)
      if v == 1 then -- option 'none'
        params:set("k2_propagate_3u", 1)
        params:hide("k2_propagate_3u")
      else
        params:show("k2_propagate_3u")
      end
      _menu.rebuild_params()
    end
  }
  params:add(k2_action)
  local k2_propagate_3u = {
    id="k2_propagate_3u",
    name="k2 propagate",
    type="binary",
    behavior="toggle",
    default=1,
  }
  params:add(k2_propagate_3u)
  if params:get("k2_action_3u") == 1 then
      params:hide("k2_propagate_3u")
      _menu.rebuild_params()
  end

  local k3_action = {
    id="k3_action_3u",
    name="k3",
    type="option",
    options=key_options_3u,
    default = pfuncs.get_index_of_value(key_options_3u, "none"),
    action = function(v)
      if v == 1 then -- option 'none'
        params:set("k3_propagate_3u", 1)
        params:hide("k3_propagate_3u")
      else
        params:show("k3_propagate_3u")
      end
      _menu.rebuild_params()
    end
  }
  params:add(k3_action)
  local k3_propagate_3u = {
    id="k3_propagate_3u",
    name="k3 propagate",
    type="binary",
    behavior="toggle",
    default=1,
  }
  params:add(k3_propagate_3u)
  if params:get("k3_action_3u") == 1 then
      params:hide("k3_propagate_3u")
      _menu.rebuild_params()
  end

  local e1_action = {
    id="3u_e1_action",
    name="e1",
    type="option",
    options=enc_options_3u,
    default = pfuncs.get_index_of_value(enc_options_3u, "none"),
    action = function(v)
      if v == 1 then -- option 'none'
        params:set("e1_propagate_3u", 1)
        params:hide("e1_propagate_3u")
      else
        params:show("e1_propagate_3u")
      end
      _menu.rebuild_params()
    end
  }
  params:add(e1_action)
  local e1_propagate_3u = {
    id="e1_propagate_3u",
    name="e1 propagate",
    type="binary",
    behavior="toggle",
    default=1,
  }
  params:add(e1_propagate_3u)
  if params:get("3u_e1_action") == 1 then
      params:hide("e1_propagate_3u")
      _menu.rebuild_params()
  end

  local e2_action = {
    id="e2_action_3u",
    name="e2",
    type="option",
    options=enc_options_3u,
    default = pfuncs.get_index_of_value(enc_options_3u, "none"),
    action = function(v)
      if v == 1 then -- option 'none'
        params:set("e2_propagate_3u", 1)
        params:hide("e2_propagate_3u")
      else
        params:show("e2_propagate_3u")
      end
      _menu.rebuild_params()
    end
  }
  params:add(e2_action)
  local e2_propagate_3u = {
    id="e2_propagate_3u",
    name="e2 propagate",
    type="binary",
    behavior="toggle",
    default=1,
  }
  params:add(e2_propagate_3u)
  if params:get("e2_action_3u") == 1 then
      params:hide("e2_propagate_3u")
      _menu.rebuild_params()
  end

  local e3_action = {
    id="e3_action_3u",
    name="e3",
    type="option",
    options=enc_options_3u,
    default = pfuncs.get_index_of_value(enc_options_3u, "none"),
    action = function(v)
      if v == 1 then -- option 'none'
        params:set("e3_propagate_3u", 1)
        params:hide("e3_propagate_3u")
      else
        params:show("e3_propagate_3u")
      end
      _menu.rebuild_params()
    end
  }
  params:add(e3_action)

  local e3_propagate_3u = {
    id="e3_propagate_3u",
    name="e3 propagate",
    type="binary",
    behavior="toggle",
    default=1,
  }
  params:add(e3_propagate_3u)
  if params:get("e3_action_3u") == 1 then
      params:hide("e3_propagate_3u")
      _menu.rebuild_params()
  end

  local draw_changes = {
    id="draw_changes",
    name="draw changes",
    type="binary",
    behavior="toggle",
    default=0
  }
  params:add(draw_changes)

  local mft_animate_param = {
    id="mft_animate_3u",
    name="animate MFT",
    type="binary",
    behavior="toggle",
    default=1,
    action=function(z)
      if z == 0 then
        for _,t in pairs(mft_animators) do
          if t.id then
            clock.cancel(t.id)
            t.id = nil
          end
        end
      else
        for _,t in pairs(mft_animators) do
          if not t.id then
            t.id = clock.run(t.func)
          end
        end
      end
    end
  }
  params:add(mft_animate_param)
  ----- BEGIN MIDI FIGHTER TWISTER (MFT) CONFIG -----
  -- params:add_separator("mft_settings", "midi fighter twister")

  mft_rgb_brightness_default = 35 -- ~equiv to value 100 in mft brightness config
  mft_indicator_brightness_default = 75 -- ~equiv to value 100 in mft brightness config
  mft_long_press_threshold = .1

  -- key: number of indicator dots to be fully lit
  -- value: the cc value that needs to be sent to an encoder configured in "blended bar" mode to light that many dots
  local mft_ind_n_val = {}
  mft_ind_n_val[0] = 0
  mft_ind_n_val[1] = 12
  mft_ind_n_val[2] = 23
  mft_ind_n_val[3] = 35
  mft_ind_n_val[4] = 46
  mft_ind_n_val[5] = 58
  mft_ind_n_val[6] = 69
  mft_ind_n_val[7] = 81
  mft_ind_n_val[8] = 92
  mft_ind_n_val[9] = 104
  mft_ind_n_val[10] = 115
  mft_ind_n_val[11] = 127

  -- key: number of indicator dots to be fully lit when an encoder is in detent (centered) and blended bar mode, where 0 is centered, positive is clockwise, negative is ccw
  -- value: cc to send to encoder
  local mft_ind_n_detent_val = {}
  mft_ind_n_detent_val[-5] = 0
  mft_ind_n_detent_val[-4] = 11
  mft_ind_n_detent_val[-3] = 24
  mft_ind_n_detent_val[-2] = 37
  mft_ind_n_detent_val[-1] = 50
  mft_ind_n_detent_val[0] = 63
  mft_ind_n_detent_val[1] = 76
  mft_ind_n_detent_val[2] = 89
  mft_ind_n_detent_val[3] = 102
  mft_ind_n_detent_val[4] = 115
  mft_ind_n_detent_val[5] = 127

  local mft_ind_n_dot_val = {}
  mft_ind_n_dot_val[0] = 0
  mft_ind_n_dot_val[1] = 11
  mft_ind_n_dot_val[2] = 23
  mft_ind_n_dot_val[3] = 34
  mft_ind_n_dot_val[4] = 46
  mft_ind_n_dot_val[5] = 58
  mft_ind_n_dot_val[6] = 69
  mft_ind_n_dot_val[7] = 81
  mft_ind_n_dot_val[8] = 93
  mft_ind_n_dot_val[9] = 104
  mft_ind_n_dot_val[10] = 116
  mft_ind_n_dot_val[11] = 127

  local mft_colors = {
    normal = 0,
    blue = 1,
    light_blue = 15,
    sky_blue = 30,
    teal = 40,
    green = 50,
    lime = 60,
    yellow = 65,
    goldenrod = 70,
    orange = 75,
    lava_red = 80,
    red = 85,
    magenta = 90,
    purple = 100,
    periwinkle = 110,
    soft_blue = 115,
    ocean_blue = 120
  }

  local function mft_color(enc, color)
    if type(color) == "string" then
      color = mft_colors['color']
    end

    if not color then
      error("color cannot be nil, or color name was not found in color table")
    end

    mft:cc(enc, color, 2)
  end

  -- given a "relative" midi msg with a value of 63 or 65, returns -1 or 1
  -- value returned when passed other messages is undefined
  local function msg_delta(msg)
    return (64 - msg.val) * -1
  end

  -- performing a params:delta doesn't redraw param screen, native refresh rate is slow, manually redraw for smoother visuals when on param screen
  local function p_redraw()
    if _menu.mode then
      _menu.rebuild_params()
    end
  end

  -- local mft_port_param = {
  --   id="mft_port",
  --   name="port",
  --   type="number",
  --   min=0,
  --   max=16,
  --   default=1,
  --   action=function(port)
  --     if port ~= 0 then
  --       mft = midi.connect(port)
  --     end
  --   end
  -- }
  -- params:add(mft_port_param)
  for i = 1, #midi.vports do
    if midi.vports[i].name == "Midi Fighter Twister" then
      mft = midi.connect(i)
    end
  end

  -- table of midi cc handlers, hiearchy is ch -> encoder num -> {func = function, state = {}}
  mft_handlers = {}

  local enc_chan = 1
  local enc_s_chan = 5 -- "shift" channel when encoder is turned while pressed
  local switch_chan = 2 -- channel for msg sent when encoder pressed/released (0/127)
  local side_chan = 4 -- channel for side buttons
  mft_handlers[enc_chan] = {}
  mft_handlers[enc_s_chan] = {}
  mft_handlers[switch_chan] = {}
  mft_handlers[side_chan] = {}

  mft.event = function(data)
    local msg = midi.to_msg(data)

    local success, handler = pcall(function()
      return mft_handlers[msg.ch][msg.cc].func
    end)

    if success and handler then
      handler(msg)
    end
  end

  -- template for a new mapping
  -- mft_handlers[enc_chan][enc_num] = {}
  -- mft_handlers[enc_chan][enc_num].state = {}
  -- mft_handlers[enc_chan][enc_num].func = function(msg)
  -- end

  -- side buttons are on channel 4, cc 8-13 top to bottom then l to r, 127 press 0 rel
  -- for now, assigning same functions to the side buttons on opposite sides
  -- SIDE BUTTONS 8 & 11, reset ansible
  mft_handlers[side_chan][8] = {}
  mft_handlers[side_chan][8].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[side_chan][8].func = function(msg)
    local s = mft_handlers[side_chan][8].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      params:set("reset_ansible", 1)
    else -- released
      s.pressed = false
      s.press_time = nil
    end
  end

  mft_handlers[side_chan][11] = {}
  mft_handlers[side_chan][11].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[side_chan][11].func = function(msg)
    local s = mft_handlers[side_chan][11].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      params:set("reset_ansible", 1)
    else -- released
      s.pressed = false
      s.press_time = nil
    end
  end

  -- SIDE BUTTONS 9 & 12, bang params
  mft_handlers[side_chan][9] = {}
  mft_handlers[side_chan][9].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[side_chan][9].func = function(msg)
    local s = mft_handlers[side_chan][9].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      params:bang()
    else -- released
      s.pressed = false
      s.press_time = nil
    end
  end

  mft_handlers[side_chan][12] = {}
  mft_handlers[side_chan][12].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[side_chan][12].func = function(msg)
    local s = mft_handlers[side_chan][12].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      params:bang()
    else -- released
      s.pressed = false
      s.press_time = nil
    end
  end

  -- ENC 4, txo voice 4 shape
  mft_handlers[enc_chan][4] = {}
  mft_handlers[enc_chan][4].state = {}
  mft_handlers[enc_chan][4].func = function(msg)
    params:delta('txo_voice_4_shape', msg_delta(msg))
    p_redraw()
  end

  table.insert(param_callbacks_3u['txo_voice_4_shape'], function(v)
    local min = 0
    local max = 5000
    local f = (v - min) / (max - min)
    local val = math.floor(f * 127 + 0.5)

    mft:cc(4, val, enc_chan)
  end)

  -- ENC 4 shift, txo voice 4 level
  mft_handlers[enc_s_chan][4] = {}
  mft_handlers[enc_s_chan][4].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][4].func = function(msg)
    local s = mft_handlers[enc_s_chan][4].state
    local desensitivity = 1
    local p_id = 'txo_voice_4_level'

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -10)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 10)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][4].state.enc_turned = true
      p_redraw()
    end
  end

  table.insert(param_callbacks_3u['txo_voice_4_level'], function(v)
    local min = 0
    local max = 8
    local f = (v - min) / (max - min)
    local val = math.floor(f * 127 + 0.5)

    mft:cc(4, val, enc_s_chan)
  end)

  mft_handlers[switch_chan][4] = {}
  mft_handlers[switch_chan][4].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }

  -- ENC 6, blooper loop div
  mft_handlers[enc_chan][6] = {}
  mft_handlers[enc_chan][6].state = {
    delta = 0
  }
  mft_handlers[enc_chan][6].func = function(msg)
    local s = mft_handlers[enc_chan][6].state
    local desensitivity = 5
    local p_id = "blooper_division"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      p_redraw()
    end
  end

  table.insert(param_callbacks_3u['blooper_division'], function(i)
    mft:cc(6, mft_ind_n_detent_val[i - 6], enc_chan)

    -- turn off led to indicate unsynced
    mft:cc(6, 17, 3)
  end)

  -- when changing clock tempo, turn off led to indicate unsynced
  table.insert(param_callbacks_3u["clock_bpm"], function(bpm)
    mft:cc(6, 17, 3)
  end)

  -- ENC 6 SHIFT, blooper division multiplier exponent
  mft_handlers[enc_s_chan][6] = {}
  mft_handlers[enc_s_chan][6].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][6].func = function(msg)
    local s = mft_handlers[enc_s_chan][6].state
    local desensitivity = 5
    local p_id = "blooper_div_mult_exp"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][6].state.enc_turned = true
      p_redraw()
    end
  end

  table.insert(param_callbacks_3u["blooper_div_mult_exp"], function(exp)
    -- turn off rgb led
    mft:cc(6, 17, 3)
    mft:cc(6, mft_ind_n_detent_val[exp], enc_s_chan)
  end)

  -- ENC 6 SWITCH, send sync to blooper
  mft_handlers[switch_chan][6] = {}
  mft_handlers[switch_chan][6].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[switch_chan][6].func = function(msg)
    local s = mft_handlers[switch_chan][6].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][6].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press

        else -- short press
          params:set("blooper_set_loop", 1)
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  -- ENC 7, rmc div
  mft_handlers[enc_chan][7] = {}
  mft_handlers[enc_chan][7].state = {
    delta = 0
  }
  mft_handlers[enc_chan][7].func = function(msg)
    local s = mft_handlers[enc_chan][7].state
    local desensitivity = 5
    local p_id = "rmc_division"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      p_redraw()
    end
  end

  table.insert(param_callbacks_3u['rmc_division'], function(i)
    mft:cc(7, mft_ind_n_detent_val[i - 6], enc_chan)

    -- turn off led to indicate unsynced
    mft:cc(7, 17, 3)
  end)

  -- when changing clock tempo, turn off led to indicate unsynced
  table.insert(param_callbacks_3u["clock_bpm"], function(bpm)
    mft:cc(7, 17, 3)
  end)

  -- when sending clock taps to rmc, make led regular to indicate it's synced
  -- instead putting this code in the function that sends the clock taps, so that it can differentiate between a successful and unsuccesful sync
  -- table.insert(param_callbacks_3u["rmc_send_clock_taps"], function()
  --   mft:cc(7, mft_rgb_brightness_default, 3)
  --   mft:cc(7, mft_colors['normal'], 2)
  -- end)

  -- ENC 7 SHIFT, rmc division multiplier exponent
  mft_handlers[enc_s_chan][7] = {}
  mft_handlers[enc_s_chan][7].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][7].func = function(msg)
    local s = mft_handlers[enc_s_chan][7].state
    local desensitivity = 5
    local p_id = "rmc_div_mult_exp"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][7].state.enc_turned = true
      p_redraw()
    end
  end

  table.insert(param_callbacks_3u["rmc_div_mult_exp"], function(exp)
    -- turn off rgb led
    mft:cc(7, 17, 3)
    mft:cc(7, mft_ind_n_detent_val[exp], enc_s_chan)
  end)

  -- ENC 7 SWITCH, send sync to rmc
  mft_handlers[switch_chan][7] = {}
  mft_handlers[switch_chan][7].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[switch_chan][7].func = function(msg)
    local s = mft_handlers[switch_chan][7].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][7].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press

        else -- short press
          params:set("rmc_send_clock_taps", 1)
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  -- ENC 8, wsyn curve
  mft_handlers[enc_chan][8] = {}
  mft_handlers[enc_chan][8].state = {}
  mft_handlers[enc_chan][8].func = function(msg)
    params:delta('wsyn_curve', msg_delta(msg))
    p_redraw()
  end

  table.insert(param_callbacks_3u['wsyn_curve'], function(curve)
    local min = -5
    local max = 5
    local f = (curve - min) / (max - min)
    local val = math.floor(f * 127 + 0.5)

    mft:cc(8, val, enc_chan)
  end)

  -- ENC 8 SHIFT, wsyn ramp
  mft_handlers[enc_s_chan][8] = {}
  mft_handlers[enc_s_chan][8].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][8].func = function(msg)
    local s = mft_handlers[enc_s_chan][8].state
    local desensitivity = 1
    local p_id = 'wsyn_ramp'

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][8].state.enc_turned = true
      p_redraw()
    end
  end

  table.insert(param_callbacks_3u['wsyn_ramp'], function(ramp)
    local min = -5
    local max = 5
    local f = (ramp - min) / (max - min)
    local val = math.floor(f * 127 + 0.5)

    mft:cc(8, val, enc_s_chan)
  end)

  -- ENC 8 SWITCH, reset wsyn curve and ramp
  mft_handlers[switch_chan][8] = {}
  mft_handlers[switch_chan][8].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[switch_chan][8].func = function(msg)
    local s = mft_handlers[switch_chan][8].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][8].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press
        else -- short press, trigger envelope
          params:set("wsyn_curve", 5)
          params:set("wsyn_ramp", 0)
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  -- ENC 9, wsyn fm ratio
  mft_handlers[enc_chan][9] = {}
  mft_handlers[enc_chan][9].state = {
    delta = 0
  }
  mft_handlers[enc_chan][9].func = function(msg)
    local s = mft_handlers[enc_chan][9].state
    local desensitivity = 5
    local p_id = "wsyn_fm_ratio"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      p_redraw()
    end
  end

  table.insert(param_callbacks_3u['wsyn_fm_ratio'], function(i)
    local val
    local color
    local offset = 15 -- the index of the start of 1..20
    local ratio_s = wsyn_ratios[i]
    local ratio = parse_fraction(ratio_s)

    if ratio % 1 == 0 then
      if ratio <= 10 then
        val = ratio
        color = 'normal'
      else
        val = ratio - 10
        color = 'periwinkle'
      end
    else
      val = i - 1
      color = 'red'
    end

    mft:cc(9, mft_ind_n_dot_val[val], enc_chan)
    mft:cc(9, mft_colors[color], 2)
  end)

  -- ENC 9 SHIFT, wsyn fm ratio divider
  mft_handlers[enc_s_chan][9] = {}
  mft_handlers[enc_s_chan][9].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][9].func = function(msg)
    local s = mft_handlers[enc_s_chan][9].state
    local desensitivity = 5
    local p_id = "wsyn_fm_ratio_mult_exp"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][9].state.enc_turned = true
      p_redraw()
    end
  end

  table.insert(param_callbacks_3u["wsyn_fm_ratio_mult_exp"], function(exp)
    mft:cc(9, mft_ind_n_dot_val[6+exp], enc_s_chan)
  end)

  -- ENC 9 SWITCH, reset fm ratio to 4
  mft_handlers[switch_chan][9] = {}
  mft_handlers[switch_chan][9].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[switch_chan][9].func = function(msg)
    local s = mft_handlers[switch_chan][9].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][9].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press

        else -- short press
          params:set("wsyn_fm_ratio", params:lookup_param("wsyn_fm_ratio").default)
          params:set("wsyn_fm_ratio_mult_exp", 0)
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  -- ENC 10, crow env time
  mft_handlers[enc_chan][10] = {}
  mft_handlers[enc_chan][10].state = {}
  mft_handlers[enc_chan][10].func = function(msg)
    params:delta('crow_env_time', msg_delta(msg))
    p_redraw()
  end

  local crow_env_time_param = params:lookup_param("crow_env_time")
  local crow_env_time_min = crow_env_time_param.controlspec.minval
  local crow_env_time_max = crow_env_time_param.controlspec.maxval

  table.insert(param_callbacks_3u['crow_env_time'], function(time)
    -- local min = 0.01
    -- local max = 4
    local f = (time - crow_env_time_min) / (crow_env_time_max - crow_env_time_min)
    local val = math.floor(f * 127 + 0.5)

    mft:cc(10, val, enc_chan)
  end)

  -- ENC 10 SHIFT, crow env offset
  mft_handlers[enc_s_chan][10] = {}
  mft_handlers[enc_s_chan][10].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][10].func = function(msg)
    local s = mft_handlers[enc_s_chan][10].state
    local desensitivity = 1
    local p_id = 'crow_env_offset'

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][10].state.enc_turned = true
      p_redraw()
    end
  end

  table.insert(param_callbacks_3u['crow_env_offset'], function(offset)
    local min = 0
    local max = 10
    local f = (offset - min) / (max - min)
    local val = math.floor(f * 127 + 0.5)

    mft:cc(10, val, enc_s_chan)
    enc_10_11_update_leds()
  end)

  -- ENC 10 SWITCH, trigger envelope
  mft_handlers[switch_chan][10] = {}
  mft_handlers[switch_chan][10].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[switch_chan][10].func = function(msg)
    local s = mft_handlers[switch_chan][10].state
    local out = params:get("crow_env_out")

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][10].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press

        else -- short press, trigger envelope
          crow.output[out]()
          enc_10_11_env_animate()
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  function enc_10_11_update_leds(out)
    out = out or params:get('crow_env_out')
    crow.output[out].query()

    local range = mft_rgb_brightness_default - 17
    local offset = params:get("crow_env_offset")
    local val

    if params:get("mft_animate_3u") == 1 then
      val = 17 + range * ((crow_outputs[out] + offset) / 8)
    else
      val = 17 + range * (offset / 8)
    end

    val = math.floor(val + 0.5)
    val = math.min(val, mft_rgb_brightness_default)

    mft:cc(10, val, 3)
    mft:cc(11, val, 3)
  end

  function enc_10_11_env_animate(time, ratio)
    if params:get("mft_animate_3u") == 0 then
      return
    end

    time = time or params:get('crow_env_time')
    ratio = ratio or params:get('crow_env_ratio')

    -- only redraw as fast as is necessary for smoothly changing brightness
    -- local a_time = time * ratio
    -- local r_time = time - a_time
    -- local range = mft_rgb_brightness_default - 17
    -- local a_time_per_step = a_time/range
    -- local r_time_per_step = r_time/range
    -- if a_time_per_step < 1/30 then
    --   a_time_per_step = 1/30
    -- end
    -- if r_time_per_step < 1/30 then
    --   r_time_per_step = 1/30
    -- end
    -- local a_time_end = util.time() + a_time
    -- local r_time_end = a_time_end + r_time

    -- add_animator(10, function()
    --   while util.time() < a_time_end do
    --     enc_10_11_update_leds()
    --     clock.sleep(a_time_per_step)
    --   end

    --   while util.time() < r_time_end do
    --     enc_10_11_update_leds()
    --     clock.sleep(r_time_per_step)
    --   end

    --   while crow_outputs[3] > 0 do
    --     enc_10_11_update_leds()
    --     clock.sleep(1/20)
    --   end

    --   enc_10_11_update_leds()
    -- end)

    local time_end = util.time() + time
    local out = params:get("crow_env_out")
    crow.output[out].query()

    add_animator(10, function()
      while util.time() < time_end do
        enc_10_11_update_leds(out)
        clock.sleep(1/20)
      end

      while crow_outputs[3] > 0 do
        enc_10_11_update_leds(out)
        clock.sleep(1/20)
      end

      enc_10_11_update_leds(out)
    end)
  end

  local function ratio_to_sensitivity(ratio)
    local s = 1
    if ratio <= 0.01 or ratio >= .99 then
      s = 1
    elseif ratio <= 0.02 or ratio >= .98 then
      s = 2
    else
      s = 10
    end

    return s
  end

  -- ENC 11, crow env ratio
  mft_handlers[enc_chan][11] = {}
  mft_handlers[enc_chan][11].state = {
    sensitivity = ratio_to_sensitivity(params:get("crow_env_ratio"))
  }
  mft_handlers[enc_chan][11].func = function(msg)
    local s = mft_handlers[enc_chan][11].state
    s.sensitivity = ratio_to_sensitivity(params:get("crow_env_ratio"))

    params:delta('crow_env_ratio', msg_delta(msg) * s.sensitivity)
    p_redraw()
  end

  table.insert(param_callbacks_3u['crow_env_ratio'], function(ratio)
    -- local val = 63.5
    -- val = val + (ratio - 0.5) / 0.5 * 63.5

    -- range 0.01-.99 covers the range up to 4 leds in either direction from the center
    -- furthest led is only lit when the ratio is at min (0) or max (1)
    local val
    if ratio == 0 then
      val = 0
    elseif ratio == 1 then
      val = 127
    else
      val = 63.5 + (ratio - 0.5) / 0.5 * 52
      val = math.floor(val + 0.5)
    end

    mft:cc(11, val, enc_chan)
    mft:cc(11, val, enc_s_chan)
  end)

  -- ENC 11 SHIFT, nothing for now just prevents a switch short press
  mft_handlers[enc_s_chan][11] = {}
  mft_handlers[enc_s_chan][11].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][11].func = function(msg)
    local s = mft_handlers[enc_s_chan][11].state
    local desensitivity = 5
    -- local p_id = "some_param"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        -- params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        -- params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][11].state.enc_turned = true
      p_redraw()
    end
  end

  -- ENC 11 SWITCH, flip ratio around 0.5
  mft_handlers[switch_chan][11] = {}
  mft_handlers[switch_chan][11].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false
  }
  mft_handlers[switch_chan][11].func = function(msg)
    local s = mft_handlers[switch_chan][11].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][11].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press

        else -- short press
          params:set("crow_env_ratio", 1 - params:get("crow_env_ratio"))
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  -- ENC 12, global tempo
  mft_handlers[enc_chan][12] = {}
  mft_handlers[enc_chan][12].state = {
    led_on = 1
  }
  mft_handlers[enc_chan][12].func = function(msg)
    params:delta("clock_bpm", msg_delta(msg) * 2)
    p_redraw()
  end

  local function update_enc_12_led(bpm)
    local range
    local min

    if bpm <= 40 then -- 10-40
      min = 10
      range = 30
      mft:cc(12, mft_colors['red'], 2)
    elseif bpm <= 160 then -- 41-160
      min = 41
      range = 119
      mft:cc(12, 0, 2) -- revert to normal color
    else -- 161-640
      min = 161
      range = 439
      mft:cc(12, mft_colors['periwinkle'], 2)
    end

    local f = (bpm - min) / range
    local v = math.floor(127 * f + 0.5)

    -- update indicator level for both regular and shift encoder
    mft:cc(12, v, enc_chan)
    mft:cc(12, v, enc_s_chan)
  end
  table.insert(param_callbacks_3u['clock_bpm'], update_enc_12_led)
  -- led pulses to clock, 1 pulse per beat
  -- not using because seems to have clock capped
  -- mft:cc(12, 13, 3)

  -- led pulser, 1 pulse per beat
  add_animator(12, function()
    while true do
      clock.sync(1)
      mft:cc(12, 17, 3)
      -- clock.sync(1/8)
      clock.sleep(0.01)
      mft:cc(12, mft_rgb_brightness_default, 3)
    end
  end)

  -- ENC 12 SHIFT, global tempo x2
  mft_handlers[enc_s_chan][12] = {}
  mft_handlers[enc_s_chan][12].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][12].func = function(msg)
    local s = mft_handlers[enc_s_chan][12].state
    local desensitivity = 5
    local p_id = "clock_bpm_x2"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      p_redraw()
    end
  end

  -- ENC 13 ansible clock (txo tr 4)
  mft_handlers[enc_chan][13] = {}
  mft_handlers[enc_chan][13].state = {
    delta = 0
  }
  mft_handlers[enc_chan][13].func = function(msg)
    local s = mft_handlers[enc_chan][13].state
    local desensitivity = 5
    local p_id = "clock_txo_tr_4_div_x2"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      p_redraw()
    end
  end

  local function update_enc_13_animator(div, z)
    div = div or params:get('clock_txo_tr_4_div')
    z = z or params:get('clock_txo_tr_4')

    if z == 0 then
      remove_animator(13)
    else
      add_animator(13, function()
        local function dark_blink() end

        if clock.get_beat_sec() / (div * 8) < 0.01 then
          dark_blink = function()
            clock.sync(1/(div*8))
          end
        else
          dark_blink = function()
            clock.sleep(0.01)
          end
        end

        while true do
          clock.sync(1/div)
          mft:cc(13, 17, 3)
          -- clock.sync(1/(div*8))
          -- clock.sleep(0.01)
          dark_blink()
          mft:cc(13, mft_rgb_brightness_default, 3)
        end
      end, "force")
    end
  end

  table.insert(param_callbacks_3u['clock_txo_tr_4_div'], function(div)
    local val
    local color = 0

    -- usually will be power of 2
    if div == 1 then
      val = mft_ind_n_val[1]
    elseif div == 2 then
      val = mft_ind_n_val[2]
    elseif div == 4 then
      val = mft_ind_n_val[4]
    elseif div == 8 then
      val = mft_ind_n_val[6]
    elseif div == 16 then
      val = mft_ind_n_val[7]
    elseif div == 32 then
      val = mft_ind_n_val[8]
    elseif div == 64 then
      val = mft_ind_n_val[9]
    elseif div == 128 then
      val = mft_ind_n_val[10]
    elseif div == 256 then
      val = mft_ind_n_val[11]
    else
      color = mft_colors['soft_blue']

      if 5 <= div and div <= 11 then
        val = mft_ind_n_val[div]
      else
        val = 0
      end
    end

    update_enc_13_animator(div)
    mft:cc(13, color, 2)
    mft:cc(13, val, enc_chan)
    mft:cc(13, val, enc_s_chan)
  end)

  table.insert(param_callbacks_3u['clock_txo_tr_4'], function(z)
    local rgb_brightness
    local ind_brightness

    if z == 0 then
      rgb_brightness = 17
      ind_brightness = 65
    else
      rgb_brightness = mft_rgb_brightness_default
      ind_brightness = mft_indicator_brightness_default
    end

    clock.run(function()
      mft:cc(13, rgb_brightness, 3)
      -- for some reason fails without this sleep, only 2nd command takes effect
      clock.sleep(0.01)
      mft:cc(13, ind_brightness, 3)
    end)

    update_enc_13_animator(nil, z)
  end)

  -- ENC 13 shift, nothing for now just prevents a switch short press
  mft_handlers[enc_s_chan][13] = {}
  mft_handlers[enc_s_chan][13].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][13].func = function(msg)
    local s = mft_handlers[enc_s_chan][13].state
    local desensitivity = 5
    -- local p_id = "some_param"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        -- params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        -- params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][13].state.enc_turned = true
      p_redraw()
    end
  end

  -- ENC 13 SWITCH, enable/disable txo tr 4 clock
  mft_handlers[switch_chan][13] = {}
  mft_handlers[switch_chan][13].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false -- set if the encoder is turned while pressed
  }
  mft_handlers[switch_chan][13].func = function(msg)
    local s = mft_handlers[switch_chan][13].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][13].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press

        else -- short press
          params:set("clock_txo_tr_4", 1 - params:get("clock_txo_tr_4"))
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  -- ENC 14 beads seed clock (txo tr 3)
  mft_handlers[enc_chan][14] = {}
  mft_handlers[enc_chan][14].state = {
    delta = 0
  }
  mft_handlers[enc_chan][14].func = function(msg)
    local s = mft_handlers[enc_chan][14].state
    local desensitivity = 5
    local p_id = "clock_txo_tr_3_div_x2"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      p_redraw()
    end
  end

  local function update_enc_14_animator(div, z)
    div = div or params:get('clock_txo_tr_3_div')
    z = z or params:get('clock_txo_tr_3')

    if z == 0 then
      remove_animator(14)
    else
      add_animator(14, function()
        local function dark_blink() end

        if clock.get_beat_sec() / (div * 8) < 0.01 then
          dark_blink = function()
            clock.sync(1/(div*8))
          end
        else
          dark_blink = function()
            clock.sleep(0.01)
          end
        end

        while true do
          clock.sync(1/div)
          mft:cc(14, 17, 3)
          -- clock.sync(1/(div*8))
          -- clock.sleep(0.01)
          dark_blink()
          mft:cc(14, mft_rgb_brightness_default, 3)
        end
      end, "force")
    end
  end

  table.insert(param_callbacks_3u['clock_txo_tr_3_div'], function(div)
    local val
    local color = 0

    -- usually will be power of 2
    if div == 1 then
      val = mft_ind_n_val[1]
    elseif div == 2 then
      val = mft_ind_n_val[2]
    elseif div == 4 then
      val = mft_ind_n_val[4]
    elseif div == 8 then
      val = mft_ind_n_val[6]
    elseif div == 16 then
      val = mft_ind_n_val[7]
    elseif div == 32 then
      val = mft_ind_n_val[8]
    elseif div == 64 then
      val = mft_ind_n_val[9]
    elseif div == 128 then
      val = mft_ind_n_val[10]
    elseif div == 256 then
      val = mft_ind_n_val[11]
    else
      color = mft_colors['soft_blue']

      if 5 <= div and div <= 11 then
        val = mft_ind_n_val[div]
      else
        val = 0
      end
    end

    update_enc_14_animator(div)
    mft:cc(14, color, 2)
    mft:cc(14, val, enc_chan)
    mft:cc(14, val, enc_s_chan)
  end)

  table.insert(param_callbacks_3u['clock_txo_tr_3'], function(z)
    local rgb_brightness
    local ind_brightness

    if z == 0 then
      rgb_brightness = 17
      ind_brightness = 65
    else
      rgb_brightness = mft_rgb_brightness_default
      ind_brightness = mft_indicator_brightness_default
    end

    clock.run(function()
      mft:cc(14, rgb_brightness, 3)
      -- for some reason fails without this sleep, only 2nd command takes effect
      clock.sleep(0.01)
      mft:cc(14, ind_brightness, 3)
    end)

    update_enc_14_animator(nil, z)
  end)

  -- ENC 14 shift, nothing for now just prevents a switch short press
  mft_handlers[enc_s_chan][14] = {}
  mft_handlers[enc_s_chan][14].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][14].func = function(msg)
    local s = mft_handlers[enc_s_chan][14].state
    local desensitivity = 5
    -- local p_id = "txo_cv_3_oct"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        -- params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        -- params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][14].state.enc_turned = true
      p_redraw()
    end
  end

  -- ENC 14 SWITCH, enable/disable txo tr 3 clock
  mft_handlers[switch_chan][14] = {}
  mft_handlers[switch_chan][14].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false -- set if the encoder is turned while pressed
  }
  mft_handlers[switch_chan][14].func = function(msg)
    local s = mft_handlers[switch_chan][14].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][14].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press

        else -- short press
          params:set("clock_txo_tr_3", 1 - params:get("clock_txo_tr_3"))
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  -- ENC 15, beads octave (txo cv 3)
  mft_handlers[enc_chan][15] = {}
  mft_handlers[enc_chan][15].state = {
    delta = 0
  }
  mft_handlers[enc_chan][15].func = function(msg)
    local s = mft_handlers[enc_chan][15].state
    local desensitivity = 5
    local p_id = "txo_cv_3_oct"

    s.delta = s.delta + msg_delta(msg)

    -- if delta reaches the threshold, do param delta and set internal delta to the next "step" (at the edge of range, next to the threshold that was just crossed)
    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      p_redraw()
    end
  end

  table.insert(param_callbacks_3u['txo_cv_3_note'], function(n)
    local val
    local color
    local oct
    local off

    if n <= 0 then
      oct = math.ceil(n / 12)
      off = n - (oct * 12)
    elseif n > 0 then
      oct = math.floor(n / 12)
      off = n - (oct * 12)
    end

    if off == 0 then
      color = mft_colors['normal']
      val = mft_ind_n_detent_val[oct]
    elseif off == 7 then
      color = mft_colors['lava_red']
      val =  mft_ind_n_detent_val[oct] + 6
    elseif off == -7 then
      color = mft_colors['lava_red']
      val =  mft_ind_n_detent_val[oct] - 6
    elseif off > 0 then
      color = mft_colors['magenta']
      val =  mft_ind_n_detent_val[oct] + off
    elseif off < 0 then
      color = mft_colors['magenta']
      val =  mft_ind_n_detent_val[oct] - off
    end

    -- update indicator level for both regular and shift encoder
    mft:cc(15, val, enc_chan)
    mft:cc(15, val, enc_s_chan)
    mft:cc(15, color, 2)
  end)

  -- ENC 15 SHIFT, beads fifths and octaves (txo cv 3)
  mft_handlers[enc_s_chan][15] = {}
  mft_handlers[enc_s_chan][15].state = {
    delta = 0
  }
  mft_handlers[enc_s_chan][15].func = function(msg)
    local s = mft_handlers[enc_s_chan][15].state
    local desensitivity = 3
    local p_id = "txo_cv_3_fifths_octs"

    s.delta = s.delta + msg_delta(msg)

    if s.delta % desensitivity == 0 then
      if s.delta < 0 then
        params:delta(p_id, -1)
        s.delta = desensitivity - 1
      elseif s.delta > 0 then
        params:delta(p_id, 1)
        s.delta = (desensitivity - 1) * -1
      end

      mft_handlers[switch_chan][15].state.enc_turned = true
      p_redraw()
    end
  end

  -- ENC 15 SWITCH, reset beads octave to 0
  mft_handlers[switch_chan][15] = {}
  mft_handlers[switch_chan][15].state = {
    pressed = false,
    press_time = nil,
    enc_turned = false -- set if the encoder is turned while pressed
  }
  mft_handlers[switch_chan][15].func = function(msg)
    local s = mft_handlers[switch_chan][15].state

    if msg.val == 127 then -- pressed
      s.pressed = true
      s.press_time = util.time()
      s.enc_turned = false
      mft_handlers[enc_s_chan][15].delta = 0
    elseif msg.val == 0 then -- released
      s.pressed = false

      -- if the encoder was turned, the press was for the encoder's shift
      if not s.enc_turned then
        local t = util.time()

        if t - s.press_time >= .25 then -- long press

        else -- short press
          params:set("txo_cv_3_note", 0)
        end
      else
      end

      s.press_time = nil
    else
      error("msg.val was "..msg.val..", expected it to be 0 or 127")
    end
  end

  ----- END MIDI FIGHTER TWISTER (MFT) CONFIG -----
  params:default()
  params:bang()
end)

mod.hook.register("script_post_init", "3u patch companion post init", function()
  capture_redraw()

  key_wrapped = key
  function key(n, z)
    if n == 1 then
      key_wrapped(n,z)
      return
    end

    local id = key_option_to_id_3u[key_options_3u[params:get("k"..n.."_action_3u")]]
    if (id ~= 'empty_param_3u') then
      local behavior = params:lookup_param(id).behavior
      if behavior == "toggle" and z == 1 then
        params:set(id, 1 - params:get(id))
      elseif behavior == "trigger" and z == 1 then
        params:set(id, 1)
      elseif behavior == "momentary" then
        params:set(id, z)
      end
    end

    if params:get("k"..n.."_propagate_3u") == 1 then
      key_wrapped(n, z)
    end
  end

  enc_wrapped = enc
  function enc(n, delta)
    local id = enc_option_to_id_3u[enc_options_3u[params:get("e"..n.."_action_3u")]]
    params:delta(id, delta)

    if params:get("e"..n.."_propagate_3u") == 1 then
      enc_wrapped(n, delta)
    end
  end

  function trackball_input(typ, code, val)
    local param_id
    if code == 0x00 then -- hid_events.codes.REL_X = 0x00
      param_id = trackball_option_to_id_3u[trackball_options_3u[params:get("trackball_x_action")]]
      if (params:get("trackball_x_invert") == 1) then
        val = -val
      end
    elseif code == 0x01 then -- hid_events.codes.REL_Y = 0x01
      param_id = trackball_option_to_id_3u[trackball_options_3u[params:get("trackball_y_action")]]
      if (params:get("trackball_y_invert") == 1) then
        val = -val
      end
    elseif code == 0x08 then -- hid_events.codes.REL_WHEEL = 0x08
      param_id = trackball_option_to_id_3u[trackball_options_3u[params:get("trackball_scroll_action")]]
      if (params:get("trackball_scroll_invert") == 1) then
        val = -val
      end
    end

    if (param_id) then
      params:delta(param_id, val)
    end
  end

  for i,device in pairs(hid.vports) do
    if (device.name == "Kensington SlimBlade Pro Trackball(Wired)") then
      device.event = trackball_input
    end
  end
end)

function capture_redraw()
  if redraw_capture_metro then
    print("redraw capture metro already exists")
  end

  redraw_capture_metro = metro.init(function()
    if _menu.mode == true then
      return
    elseif _menu.mode == false then
      _script_redraw = redraw
      metro.free(redraw_capture_metro.id)
      redraw_capture_metro = nil
    else
      print("_menu.mode behavior has changed, mod unable to wrap script's redraw function")
    end
  end, 1/10)
  redraw_capture_metro:start()
end

function restore_redraw(redraw_func)
  if redraw_restore_metro then
    print("redraw restore metro already exists")
    return
  elseif redraw_func == nil then
    print("redraw restore function cannot be nil")
    return
  end

  redraw_restore_metro = metro.init(function()
    if _menu.mode == true then
      return
    elseif _menu.mode == false then
      redraw = redraw_func
      metro.free(redraw_restore_metro.id)
      redraw_restore_metro = nil
    else
      print("_menu.mode behavior has changed, mod unable to restore script's redraw function")
    end
  end, 1/10)
  redraw_restore_metro:start()
end

----- BEGIN MFT LED ANIMATION SYSTEM -----
mft_animators = {}
-- for i=0,15 do
--   mft_animators[i] = {}
-- end

-- "behavior" can be 'error', 'ignore', or 'force'
function add_animator(enc, func, behavior)
  behavior = behavior or "force"

  if mft_animators[enc] ~= nil then
    if behavior == "error" then
      error("Failed to add animator to mft encoder "..enc..", animator already present")
    elseif behavior == "ignore" then
      debug_msg("Tried to add animator to mft encoder "..enc>>", animator already present, ignoring")
      return
    elseif behavior == "force" then
      if mft_animators[enc].id then
        clock.cancel(mft_animators[enc].id)
      end
    else
      error("Invalid value for param `behavior`. Valid values are 'error', 'ignore', or 'force'")
    end
  end

  local t = {
    func = func
  }

  if params:get("mft_animate_3u") == 1 then
    t.id = clock.run(func)
  end

  mft_animators[enc] = t
end

function remove_animator(enc)
  local anim_t = mft_animators[enc]

  if anim_t and anim_t.id then
    clock.cancel(anim_t.id)
  end

  mft_animators[enc] = nil
end

function enable_animate(enc, state)
  state = state or true

  local anim_t = mft_animators[enc]

  if state then
    if params:get("mft_animate_3u") ~= 1 then
      debug_msg("attempted to enable mft animation on encoder "..enc.." while the mft_animate param was false")
    elseif anim_t and not anim_t.id then
      anim_t.id = clock.run(anim_t.func)
    end
  else
    if anim_t and anim_t.id then
      clock.cancel(anim_t.id)
      anim_t.id = nil
    end
  end
end
----- END MFT LED ANIMATION SYSTEM -----

-- MOD MENU
local modmenu = include '3u-patch-companion/lib/modmenu/modmenu'
local mft_conf = require('3u-patch-companion/lib/mftconf/lib/mftconf')
local menu = modmenu.new("3u_companion_mod_menu", mod.this_name)
local mod_params = menu.params
mod_params:add{
  id="mft_load_config",
  name="load MFT config",
  type="binary",
  behavior="trigger",
  action=function()
    for i = 1, #midi.vports do
      if midi.vports[i].name == "Midi Fighter Twister" then
        mft_conf.load_conf(midi.connect(i), '/home/we/dust/code/3u-patch-companion/resources/mft-minimal-config.mfs')
      end
    end
  end,
}
mod.menu.register(mod.this_name, menu)

debug_3u = true
function debug_msg(s)
  if debug_3u then
    print("debug: "..s)
  end
end
