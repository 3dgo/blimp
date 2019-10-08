#pragma once

#include "event/event.h"

#include <sstream>

namespace blimp
{
    class KeyEvent : public Event
    {
    public:
        inline int get_keycode() const { return keycode; }

        EVENT_CLASS_CATEGORY(EventCategoryKeyboard | EventCategoryInput)

    protected:
        KeyEvent(int keycode)
            : keycode(keycode) {}

        int keycode;
    };

    class KeyPressedEvent : public KeyEvent
    {
    public:
        KeyPressedEvent(int keycode, int repeat_count)
            : KeyEvent(keycode), repeat_count(repeat_count) {}

        inline int get_repeat_count() const { return repeat_count; }

        std::string to_string() const override
        {
            std::stringstream ss;
            ss << "KeyPressedEvent: " << keycode << " (" << repeat_count << " repeats)";
            return ss.str();
        }

        EVENT_CLASS_TYPE(KeyPressed)

    private:
        int repeat_count;
    };

    class KeyReleasedEvent : public KeyEvent
    {
    public:
        KeyReleasedEvent(int keycode)
            : KeyEvent(keycode) {}
        
        std::string to_string() const override
        {
            std::stringstream ss;
            ss << "KeyReleasedEvent: " << keycode;
            return ss.str();
        }

        EVENT_CLASS_TYPE(KeyReleased)
    }
}