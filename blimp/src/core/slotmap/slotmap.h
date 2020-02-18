//
// Created by lucien on 2/17/20.
//
#pragma once

#include <vector>
#include "core/object/object.h"
#include <array>

namespace blimp
{
    const int chunk_size = 8;

    struct SlotID
    {
        SlotID(int ind, int gen) : ind(ind), gen(gen) {}
        int ind = -1;
        int gen = 0;

        bool operator==(const SlotID& rhs) const
        {
            return ind == rhs.ind && gen == rhs.gen;
        }
    };

    std::vector<std::array<Object, chunk_size>*> data;
    std::vector<SlotID> slot_ids;
    std::vector<int> free_list;

    SlotID create_object()
    {
        if(free_list.empty())
        {
            std::array<Object, chunk_size>* chunk = new std::array<Object, chunk_size>;
            data.push_back(chunk);

            slot_ids.reserve(data.size() * chunk_size);
            free_list.reserve(free_list.size() + chunk_size);
            for(int i = 0; i < chunk_size; i++)
            {
                slot_ids.push_back(SlotID(slot_ids.size(),0));
                free_list.push_back(data.size() * chunk_size - i - 1);
            }
        }

        int free_slot = free_list.back();
        free_list.pop_back();

        return slot_ids[free_slot];
    }

    Object* get_object(SlotID id)
    {
        if(id.ind >= data.size() * chunk_size || id.ind < 0 || id.gen < 0)
        {
            return nullptr;
        }

        SlotID slot = slot_ids[id.ind];
        if(slot == id)
        {
            return &(*data[id.ind / chunk_size])[id.ind % chunk_size];
        }
        return nullptr;
    }

    void destroy_object(SlotID id)
    {
        Object* obj = get_object(id);

        if(obj)
        {
            slot_ids[id.ind].gen++;
            free_list.push_back(id.ind);
        }

    }
}
