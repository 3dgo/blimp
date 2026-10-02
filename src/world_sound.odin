package blimp

import "core:log"
import "core:math/linalg"
import "core:os"
import "core:path/filepath"
import "core:strings"
import hm "core:container/handle_map"
import ma "vendor:miniaudio"
import "common"

// Sound (docs/gameplay.md → Sound). miniaudio's engine mixes on its own audio thread; the game side is
// fire-and-forget commands into a fixed pool of voices. A voice is a copy of a clip's ma.sound: every
// ma_sound_* call is a lock-free post (atomics) to the mixer, so the game thread never touches mixer state.
//
// - Clips: every .wav .ogg .mp3 .flac under assets/ and assets_engine/, decoded at startup (assets load at
//   init), keyed by project path like any asset (asset_intern). Hot reload reloads them all.
// - Voices: MAX_VOICES. A new sound with no free voice steals the quietest playing one (volume × distance
//   falloff at the listener), oldest first on a tie; if the new one would be the quietest, it's dropped.
// - Coalescing: a clip doesn't start again within SOUND_COALESCE_SEC of its last start (a hundred coins
//   picked up in one frame are one sound). Looping sounds are exempt.
// - A voice belongs to a world. One attached to an entity follows it and stops when the entity goes. A play
//   world's voices pause while it doesn't tick (paused) and stop with it. Edited levels make no sound.
// - Handles (Sound_Handle) are generation-indexed, so a stale one is a safe no-op. Lua never gets one:
//   it plays an entity's own sound, and the entity is the handle (Entity.play_sound / stop_sound).
// - Listener: the camera of the view showing a playing world (its game camera in game mode).
// miniaudio is right-handed (-Z forward); the engine is left-handed, so z is negated at the boundary.

MAX_VOICES          :: 32
SOUND_COALESCE_SEC  :: 0.05
SOUND_DEFAULT_RANGE :: vec2{1, 30}   // World.play_sound_at's falloff

Sound_Clip :: struct {
    key:        string,     // its project path (asset_intern)
    sound:      ma.sound,   // decoded once, never played: voices are copies sharing its data
    last_start: f64,        // timer_sec_since_init of its last voice (coalescing)
}

Voice :: struct {
    sound:      ma.sound,
    clip:       int,             // index into clips; -1 = free
    generation: u32,             // bumped each time the slot is reused; never 0
    world:      ^World,
    entity:     Entity_Handle,   // {} = stays where it started
    position:   vec3,
    positional: bool,
    looping:    bool,
    volume:     f32,
    range:      vec2,            // full volume inside x, silent at y (positional)
    started:    f64,
    paused:     bool,            // stopped because its world doesn't tick
}

Sound_Handle :: struct {
    index, generation: u32,
}

Sound_System :: struct {
    engine:   ma.engine,
    ok:       bool,             // the audio device opened; false = every command is a silent no-op
    clips:    []Sound_Clip,     // fixed once loaded: miniaudio keeps pointers into each ma.sound
    clip_ids: map[string]int,
    voices:   [MAX_VOICES]Voice,
    listener: vec3,
}
sound_system: Sound_System

sound_init :: proc() {
    s := &sound_system
    for &v in s.voices do v.clip, v.generation = -1, 1   // generation 0 is never live, so a zero Sound_Handle means none
    config := ma.engine_config_init()
    if r := ma.engine_init(&config, &s.engine); r != .SUCCESS {
        log.errorf("Sound: no audio device (%v); the game is silent", r)
        return
    }
    s.ok = true
    ma.engine_listener_set_world_up(&s.engine, 0, 0, 1, 0)
    sound_load_clips()
}

sound_shutdown :: proc() {
    s := &sound_system
    if !s.ok do return
    sound_unload_clips()
    ma.engine_uninit(&s.engine)
    s.ok = false
}

// Hot reload (asset_hot_reload.odin): a sound file changed. Every voice stops; clips load again.
sound_reload :: proc() {
    if !sound_system.ok do return
    sound_unload_clips()
    sound_load_clips()
}

@(private="file")
sound_load_clips :: proc() {
    s := &sound_system
    files := make([dynamic]os.File_Info, context.temp_allocator)
    for root in ([]string{"./assets_engine", "./assets"}) do common.get_all_files(root, &files, context.temp_allocator)
    paths := make([dynamic]string, context.temp_allocator)
    for fi in files {
        switch strings.to_lower(filepath.ext(fi.fullpath), context.temp_allocator) {
        case ".wav", ".ogg", ".mp3", ".flac": append(&paths, fi.fullpath)
        }
    }

    s.clips = make([]Sound_Clip, len(paths), app.allocators.perm)
    s.clip_ids = make(map[string]int, app.allocators.perm)
    n := 0
    for path in paths {
        c := &s.clips[n]
        r := ma.sound_init_from_file(&s.engine, strings.clone_to_cstring(path, context.temp_allocator), {.DECODE, .NO_DEFAULT_ATTACHMENT}, nil, nil, &c.sound)
        if r != .SUCCESS {
            log.warnf("Sound: can't load '%v' (%v)", path, r)
            continue
        }
        c.key = asset_intern(asset_key(path, context.temp_allocator))
        s.clip_ids[c.key] = n
        n += 1
    }
    s.clips = s.clips[:n]
    log.infof("Sound: %v clips", n)
}

@(private="file")
sound_unload_clips :: proc() {
    s := &sound_system
    for &v in s.voices do if v.clip >= 0 do voice_free(&v)
    for &c in s.clips do ma.sound_uninit(&c.sound)
    delete(s.clips, app.allocators.perm)
    delete(s.clip_ids)
    s.clips, s.clip_ids = nil, nil
}

// Sound file keys, for the inspector's picker.
sound_clip_keys :: proc(allocator := context.allocator) -> []string {
    keys := make([]string, len(sound_system.clips), allocator)
    for c, i in sound_system.clips do keys[i] = c.key
    return keys
}

// ============================ Commands ============================

Sound_Params :: struct {
    position:   vec3,
    entity:     Entity_Handle,   // follow this entity of the world ({} = stay at position)
    positional: bool,
    looping:    bool,
    volume:     f32,
    range:      vec2,
}

// Starts clip `key` in world w. A zero handle when it didn't start: unknown clip, coalesced, every voice
// louder, or no audio device.
sound_play :: proc(w: ^World, key: string, p: Sound_Params) -> Sound_Handle {
    s := &sound_system
    if !s.ok || key == "" do return {}
    clip_index, found := s.clip_ids[key]
    if !found {
        log.warnf("Sound: no clip '%v'", key)
        return {}
    }
    clip := &s.clips[clip_index]
    now := timer_sec_since_init()
    if !p.looping && clip.last_start > 0 && now - clip.last_start < SOUND_COALESCE_SEC do return {}

    // A free voice, else the quietest (oldest on a tie), unless the new sound is quieter still.
    loudness := voice_loudness(p.volume, p.positional, p.position, p.range)
    slot := -1
    for v, i in s.voices do if v.clip < 0 { slot = i; break }
    if slot < 0 {
        quietest := max(f32)
        for &v, i in s.voices {
            l := voice_loudness(v.volume, v.positional, v.position, v.range)
            if l < quietest || (l == quietest && v.started < s.voices[slot].started) do quietest, slot = l, i
        }
        if loudness < quietest do return {}
        voice_free(&s.voices[slot])
    }

    v := &s.voices[slot]
    flags: ma.sound_flags
    if !p.positional do flags += {.NO_SPATIALIZATION}
    if r := ma.sound_init_copy(&s.engine, &clip.sound, flags, nil, &v.sound); r != .SUCCESS {
        log.warnf("Sound: can't start '%v' (%v)", key, r)
        return {}
    }
    v.clip, v.world, v.entity = clip_index, w, p.entity
    v.position, v.positional, v.looping, v.volume, v.range = p.position, p.positional, p.looping, p.volume, p.range
    v.started, v.paused = now, false
    clip.last_start = now

    ma.sound_set_looping(&v.sound, b32(p.looping))
    ma.sound_set_volume(&v.sound, p.volume)
    if p.positional {
        ma.sound_set_attenuation_model(&v.sound, .linear)
        ma.sound_set_rolloff(&v.sound, 1)
        ma.sound_set_min_distance(&v.sound, p.range.x)
        ma.sound_set_max_distance(&v.sound, max(p.range.y, p.range.x + 0.01))
        ma.sound_set_doppler_factor(&v.sound, 0)
        ma.sound_set_position(&v.sound, p.position.x, p.position.y, -p.position.z)
    }
    ma.sound_start(&v.sound)
    return {u32(slot), v.generation}
}

// Stops a voice; a stale handle (that voice finished, or was stolen) does nothing.
sound_stop :: proc(h: Sound_Handle) {
    if h == {} || int(h.index) >= MAX_VOICES do return
    v := &sound_system.voices[h.index]
    if v.clip >= 0 && v.generation == h.generation do voice_free(v)
}

// Plays entity e's own sound in world w (its sound, volume, range and sound flags), attached to it.
entity_sound_play :: proc(w: ^World, h: Entity_Handle) -> Sound_Handle {
    e, ok := entity_get(w, h)
    if !ok do return {}
    return sound_play(w, e.sound, {
        position = e.position, entity = h, positional = .Positional in e.sound_flags,
        looping = .Loop in e.sound_flags, volume = e.volume, range = e.range,
    })
}

// Stops every voice attached to entity h of w.
entity_sound_stop :: proc(w: ^World, h: Entity_Handle) {
    for &v in sound_system.voices do if v.clip >= 0 && v.world == w && v.entity == h do voice_free(&v)
}

// Play mode starts (world_play): the entities whose sound plays on start.
sound_world_start :: proc(w: ^World) {
    it := hm.iterator_make(&w.entities)
    for e, h in hm.iterate(&it) {
        if e.sound != "" && .Play_On_Start in e.sound_flags && .Enabled in e.basic_flags do entity_sound_play(w, h)
    }
}

// The world stops playing or closes: its voices stop.
sound_world_stop :: proc(w: ^World) {
    for &v in sound_system.voices do if v.clip >= 0 && v.world == w do voice_free(&v)
}

// ============================ Per frame ============================

// After the game systems: the listener, attached voices following their entities, pausing with their
// world, and finished voices freed.
sound_update :: proc() {
    s := &sound_system
    if !s.ok do return

    // The listener: the camera of the view showing a playing world, the game view's first.
    listener_view: ^Render_View
    for v in views do if v.world.play_source != nil && (listener_view == nil || v == ui.game) do listener_view = v
    if listener_view == nil do listener_view = active_view
    if lv := listener_view; lv != nil {
        eye, fwd := camera_eye(lv.camera), camera_forward(lv.camera)
        if e, ok := render_view_game_camera(lv); ok do eye, fwd = e.position, entity_forward(e)
        s.listener = eye
        ma.engine_listener_set_position(&s.engine, 0, eye.x, eye.y, -eye.z)
        ma.engine_listener_set_direction(&s.engine, 0, fwd.x, fwd.y, -fwd.z)
    }

    for &v in s.voices {
        if v.clip < 0 do continue
        if !v.looping && ma.sound_at_end(&v.sound) {
            voice_free(&v)
            continue
        }
        if v.entity != {} {
            e, ok := entity_get(v.world, v.entity)
            if !ok {
                voice_free(&v)
                continue
            }
            v.position = e.position
            if v.positional do ma.sound_set_position(&v.sound, v.position.x, v.position.y, -v.position.z)
        }
        ticks := v.world.play_source == nil || v.world.ticks
        if !ticks && !v.paused {
            ma.sound_stop(&v.sound)
            v.paused = true
        } else if ticks && v.paused {
            ma.sound_start(&v.sound)
            v.paused = false
        }
    }
}

@(private="file")
voice_free :: proc(v: ^Voice) {
    ma.sound_uninit(&v.sound)
    v.clip = -1
    v.entity, v.world = {}, nil
    v.generation += 1
}

// Roughly how loud a voice is at the listener: its volume × the linear falloff (voice stealing).
@(private="file")
voice_loudness :: proc(volume: f32, positional: bool, position: vec3, range: vec2) -> f32 {
    if !positional do return volume
    d := linalg.distance(position, sound_system.listener)
    return volume * (1 - clamp((d - range.x) / max(range.y - range.x, 0.01), 0, 1))
}

// ============================ Lua ============================

// Plays the entity's own sound (its Sound, Volume, Range and Sound Flags), following it. False if it
// didn't start.
@(lua=play_sound, table=Entity, lua_zh="播放声音")
entity_play_sound_lua :: proc(handle: Entity_Handle) -> bool {
    return entity_sound_play(lua_world(), handle) != {}
}

@(lua=stop_sound, table=Entity, lua_zh="停止声音")
entity_stop_sound_lua :: proc(handle: Entity_Handle) {
    entity_sound_stop(lua_world(), handle)
}

// A sound file (its project path) that isn't anywhere: music, UI, the same volume everywhere.
@(lua=play_sound, table=World, lua_zh="播放声音")
world_play_sound_lua :: proc(key: string, volume: f32 = 1) -> bool {
    return sound_play(lua_world(), key, {volume = volume}) != {}
}

// A sound file at a point, fading out over SOUND_DEFAULT_RANGE. For something that moves, or a range of
// its own, give an entity the sound and use Entity.play_sound.
@(lua=play_sound_at, table=World, lua_zh="在位置播放声音")
world_play_sound_at_lua :: proc(key: string, position: vec3, volume: f32 = 1) -> bool {
    return sound_play(lua_world(), key, {position = position, positional = true, volume = volume, range = SOUND_DEFAULT_RANGE}) != {}
}
