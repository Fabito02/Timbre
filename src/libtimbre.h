#ifndef LIBTIMBRE_H
#define LIBTIMBRE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TimbrePlayerHandle TimbrePlayerHandle;

typedef void (*TimbreCallback)(void *ud, char *json, char *error);
typedef void (*TimbreDoneCallback)(void *ud, bool success, char *error);

TimbrePlayerHandle *timbre_player_new(void);
void timbre_player_free(TimbrePlayerHandle *handle);

void timbre_string_free(char *ptr);

void timbre_set_log_level(int level);

void timbre_set_log_level(int level);

void timbre_set_locale(const char *hl, const char *gl);

bool timbre_player_play_file(TimbrePlayerHandle *h, const char *path);

bool timbre_player_play_url(TimbrePlayerHandle *h, const char *url,
                            uint64_t duration_secs, TimbreDoneCallback cb,
                            void *ud);

bool timbre_player_play_track_id(TimbrePlayerHandle *h, const char *track_id,
                                 uint64_t duration_secs, TimbreDoneCallback cb,
                                 void *ud);

void timbre_player_pause(TimbrePlayerHandle *h);
void timbre_player_resume(TimbrePlayerHandle *h);
void timbre_player_stop(TimbrePlayerHandle *h);
void timbre_player_reset(TimbrePlayerHandle *h);
bool timbre_player_seek(TimbrePlayerHandle *h, double target_secs);

double timbre_player_get_position(TimbrePlayerHandle *h);
double timbre_player_get_duration(TimbrePlayerHandle *h);
bool timbre_player_is_finished(TimbrePlayerHandle *h);
bool timbre_player_is_paused(TimbrePlayerHandle *h);

void timbre_audio_release_sink(TimbrePlayerHandle *h);
bool timbre_audio_rebuild_sink(TimbrePlayerHandle *h);
void timbre_player_set_active(TimbrePlayerHandle *h, bool active);

void timbre_player_set_volume(TimbrePlayerHandle *h, float v);
float timbre_player_get_volume(TimbrePlayerHandle *h);

int timbre_player_get_state(TimbrePlayerHandle *h);

char *timbre_player_take_last_error(TimbrePlayerHandle *h);

char *timbre_player_get_stats(TimbrePlayerHandle *h);

char *timbre_audio_stats(TimbrePlayerHandle *h);
char *timbre_audio_list(TimbrePlayerHandle *h, int kind);

bool timbre_audio_remove(TimbrePlayerHandle *h, const char *video_id,
                         TimbreDoneCallback cb, void *ud);
bool timbre_audio_clear(TimbrePlayerHandle *h, int kind, TimbreDoneCallback cb,
                        void *ud);
void timbre_audio_set_cache_limit(TimbrePlayerHandle *h, uint64_t bytes);

bool timbre_audio_download(TimbrePlayerHandle *h, const char *track_id,
                           TimbreDoneCallback cb, void *ud);

bool timbre_player_get_home(TimbrePlayerHandle *h, TimbreCallback cb, void *ud);
bool timbre_player_get_explore(TimbrePlayerHandle *h, TimbreCallback cb,
                               void *ud);
bool timbre_player_get_charts(TimbrePlayerHandle *h, const char *country,
                              TimbreCallback cb, void *ud);
bool timbre_player_get_mood_categories(TimbrePlayerHandle *h, TimbreCallback cb,
                                       void *ud);
bool timbre_player_get_category_page(TimbrePlayerHandle *h, const char *params,
                                     TimbreCallback cb, void *ud);

bool timbre_player_get_album(TimbrePlayerHandle *h, const char *album_id,
                             TimbreCallback cb, void *ud);
bool timbre_player_get_playlist(TimbrePlayerHandle *h, const char *playlist_id,
                                TimbreCallback cb, void *ud);
bool timbre_player_get_artist(TimbrePlayerHandle *h, const char *channel_id,
                              TimbreCallback cb, void *ud);
bool timbre_player_browse_section(TimbrePlayerHandle *h, const char *args_json,
                                  TimbreCallback cb, void *ud);
bool timbre_player_get_radio(TimbrePlayerHandle *h, const char *track_id,
                             TimbreCallback cb, void *ud);
bool timbre_player_get_watch_playlist(TimbrePlayerHandle *h,
                                      const char *video_id,
                                      const char *playlist_id,
                                      TimbreCallback cb, void *ud);

bool timbre_player_get_library_playlists(TimbrePlayerHandle *h,
                                         TimbreCallback cb, void *ud);
bool timbre_player_get_library_albums(TimbrePlayerHandle *h, TimbreCallback cb,
                                      void *ud);
bool timbre_player_get_library_subscriptions(TimbrePlayerHandle *h,
                                             TimbreCallback cb, void *ud);
bool timbre_player_get_history(TimbrePlayerHandle *h, TimbreCallback cb,
                               void *ud);

bool timbre_player_search(TimbrePlayerHandle *h, const char *query,
                          TimbreCallback cb, void *ud);
bool timbre_player_search_suggestions(TimbrePlayerHandle *h, const char *query,
                                      TimbreCallback cb, void *ud);

bool timbre_player_get_account(TimbrePlayerHandle *h, TimbreCallback cb,
                               void *ud);
bool timbre_player_is_authenticated(TimbrePlayerHandle *h);

bool timbre_player_login(TimbrePlayerHandle *h, const char *input,
                         TimbreDoneCallback cb, void *ud);
bool timbre_player_logout(TimbrePlayerHandle *h, TimbreDoneCallback cb,
                          void *ud);

bool timbre_player_rate_track(TimbrePlayerHandle *h, const char *track_id,
                              int rating, TimbreDoneCallback cb, void *ud);

bool timbre_player_subscribe_artist(TimbrePlayerHandle *h,
                                    const char *channel_id, bool subscribe,
                                    TimbreDoneCallback cb, void *ud);

bool timbre_player_remove_history(TimbrePlayerHandle *h,
                                  const char *tokens_json,
                                  TimbreDoneCallback cb, void *ud);

bool timbre_player_add_to_playlist(TimbrePlayerHandle *h,
                                   const char *playlist_id,
                                   const char *track_ids_json,
                                   TimbreDoneCallback cb, void *ud);

bool timbre_player_create_playlist(TimbrePlayerHandle *h, const char *title,
                                   const char *description, const char *privacy,
                                   TimbreCallback cb, void *ud);

bool timbre_player_delete_playlist(TimbrePlayerHandle *h,
                                   const char *playlist_id,
                                   TimbreDoneCallback cb, void *ud);

bool timbre_player_edit_playlist(TimbrePlayerHandle *h, const char *playlist_id,
                                 const char *title, const char *description,
                                 const char *privacy, TimbreDoneCallback cb,
                                 void *ud);

bool timbre_player_record_play_start(TimbrePlayerHandle *h, const char *track_id,
                                     TimbreDoneCallback cb, void *ud);
void timbre_player_record_play_tick(TimbrePlayerHandle *h, const char *track_id,
                                    double position_secs);
void timbre_player_record_play_end(TimbrePlayerHandle *h, const char *track_id);

#ifdef __cplusplus
}
#endif

#endif /* LIBTIMBRE_H */
