//
// Created by lucien on 2/13/20.
//

#pragma once

#include "system.h"
#include <string>
#include <SDL.h>

namespace blimp
{
    class Engine : public System<Engine> {

    public:
        virtual bool init() override;
        virtual void run();
        virtual void shutdown() override;

        void set_window_name(const std::string& name);

    protected:
        void check_SDL_error();


    private:
        SDL_Window* window = nullptr;
        SDL_GLContext context = nullptr;
        std::string window_name = "blimp";
        int drawableX, drawableY = 0;
    };
}
