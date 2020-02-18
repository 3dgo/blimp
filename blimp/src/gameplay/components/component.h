//
// Created by lucien on 2/16/20.
//

#pragma once


namespace blimp
{
    class Component : public Object
    {

    DECLARE_ABSTRACT_DERIVED_CLASS(Component, Object)

    public:
        Component();
        ~Component();

    };
}


