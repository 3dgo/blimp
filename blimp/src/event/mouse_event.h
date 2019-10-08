#pragma once

#include "event/event.h"

#include <sstream>

namespace blimp
{
    class MouseMovedEvent : public Event
    {
    public:
        MouseMovedEvent(float x, float y)
            : mouse_x(x), mouse_y(y) {}

        inline float get_x() const { return mouse_x; }
        inline float get_y() const { return mouse_y; }
        
        std::string to_string() const override
        {
            std::stringstream ss;
            ss << "MouseMovedEvent: " << mouse_x << ", " << mouse_y;
            return ss.str();
        }

        EVENT_CLASS_TYPE(MouseMoved)
        EVENT_CLASS_CATEGORY(EventCategoryMouse | EventCategoryInput)

    private:
        float mouse_x, mouse_y;
    };

    class MouseButtonEvent : public Event
    {
    public:
        inline int get_mouse_button() const { return button; }

        EVENT_CLASS_CATEGORY(EventCategoryMouse | EventCategoryInput)
    protected:
        MouseButtonEvent(int button)
            : button(button) {}

        int button;
    };

    class MouseButtonPressedEvent : public MouseButtonEvent
    {
    public:
        MouseButtonPressedEvent(int button)
            : MouseButtonEvent(button) {}

        std::string to_string() const override
        {
            std::stringstream ss;
            ss << "MouseButtonPressedEvent: " << button;
            return ss.str();
        }
    };

    class MouseButtonReleasedEvent : public MouseButtonEvent
    {
    public:
        MouseButtonReleasedEvent(int button)
            : MouseButtonEvent(button) {}

        std::string to_string() const override
        {
            std::stringstream ss;
            ss << "MouseButtonReleasedEvent: " << button;
            return ss.str();
        }

        EVENT_CLASS_TYPE(MouseButtonReleased)
    };
}